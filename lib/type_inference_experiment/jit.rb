require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'

class JIT
  def initialize(code)
    @code = code
    @instructions = Compiler.new(code).compile
    @typed_instructions = InferenceEngine.new(@instructions, code: code).infer
    @scope = [{ vars: {}, stack: [], return_type: nil }]
    @methods = {}
    @module = LLVM::Module.new('JIT')
    @builder = LLVM::Builder.new
    @index = 0
  end

  def run
    @scope.last[:return_type] = return_type = @typed_instructions.last.type
    @module.functions.add('main', [], to_llvm_type(return_type)) do |main|
      main.basic_blocks.append('entry').build do |builder|
        walk(main, builder)

        return_val = stack.pop
        if return_type == :str
          zero = LLVM.Int(0)
          builder.ret(builder.gep(return_val, [zero, zero]))
        else
          builder.ret(return_val)
        end
      end
    end
    LLVM.init_jit
    @module.verify
    # @module.dump # debug IR
    engine = LLVM::JITCompiler.new(@module)
    result = engine.run_function(@module.functions['main'])
    engine.dispose
    case return_type
    when :str
      result.to_ptr.read_string
    when :int
      result.to_i
    else
      raise "unknown return type: #{return_type}"
    end
  end

  private

  def walk(function, builder)
    while @index < @typed_instructions.size
      typed_instruction = @typed_instructions[@index]
      instruction = typed_instruction.instruction

      case instruction.type
      when :push_int
        stack << LLVM.Int(instruction.arg)
      when :push_str
        val = LLVM::ConstantArray.string(instruction.arg)
        var = builder.alloca(val.type)
        builder.store(val, var)
        stack << builder.load(var)
      when :set_var
        val = stack.pop
        var = vars[instruction.arg] = builder.alloca(val.type)
        builder.store(val, var)
      when :push_var
        var = vars[instruction.arg]
        val = if var.is_a?(LLVM::Instruction) # stack var
                builder.load(var)
              else # register
                var
              end
        stack << val
      when :push_nil
        stack << nil # TODO
      when :def
        # collect all the arguments
        @index += 1
        args = []
        while (push_arg = @typed_instructions[@index].instruction).type == :push_arg
          @index += 1
          set_var = @typed_instructions[@index].instruction
          raise 'unexpected' unless set_var.type == :set_var
          args[push_arg.arg] = [@typed_instructions[@index].type, set_var.arg]
          @index += 1
        end
        # build function
        @module.functions.add(
          instruction.arg,
          args.map { |t, _| to_llvm_type(t) },
          to_llvm_type(typed_instruction.type)
        ) do |f, *llvm_args|
          @methods[instruction.arg] = f
          @scope << { vars: {}, stack: [], return_type: typed_instruction.type }
          args.each_with_index do |(_type, name), idx|
            llvm_args[idx].name = name.to_s
            vars[name] = llvm_args[idx]
          end
          f.basic_blocks.append('entry').build do |b|
            walk(f, b)
          end
          @scope.pop
        end
      when :end_def
        val = stack.pop
        builder.ret(val)
        return
      when :send
        case instruction.arg
        when :+
          raise 'wrong num of args' unless instruction.extra_arg == 1
          rhs = stack.pop
          lhs = stack.pop
          stack << builder.add(lhs, rhs)
        else
          func = @methods[instruction.arg]
          args = []
          arg_count = instruction.extra_arg
          arg_count.times do
            args << stack.pop
          end
          stack.pop # get rid of nil receiver on stack
          stack << builder.call(func, *args)
        end
      else
        raise "unknown JIT instruction: #{instruction.inspect}"
      end

      @index += 1
    end
  end

  def stack
    @scope.last.fetch(:stack)
  end

  def vars
    @scope.last.fetch(:vars)
  end

  def args
    @scope.last.fetch(:args)
  end

  def to_llvm_type(type)
    case type
    when :str
      LLVM::Type.pointer(LLVM::UInt8)
    when :int
      LLVM::Int
    else
      raise "unknown type: #{type}"
    end
  end
end
