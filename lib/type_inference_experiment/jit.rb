require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'

class JIT
  def initialize(code)
    @code = code
    @instructions = Compiler.new(code).compile
    @typed_instructions = InferenceEngine.new(@instructions, code: code).infer
    @scope = [{ vars: {}, stack: [] }]
    @methods = {}
    @module = LLVM::Module.new('JIT')
    @builder = LLVM::Builder.new
  end

  def run
    return_type = @typed_instructions.last.type
    @module.functions.add('main', [], to_llvm_type(return_type)) do |main|
      entry = main.basic_blocks.append('entry')
      entry.build do |builder|
        index = 0
        while index < @typed_instructions.size
          typed_instruction = @typed_instructions[index]
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
            val = builder.load(var)
            stack << val
          else
            raise "unknown JIT instruction: #{instruction.inspect}"
          end

          index += 1
        end

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
