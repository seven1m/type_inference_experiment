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
    LLVM.init_jit
    @module.functions.add('main', [], LLVM::Int) do |main|
      entry = main.basic_blocks.append('entry')
      entry.build do |builder|
        index = 0
        while index < @typed_instructions.size
          typed_instruction = @typed_instructions[index]
          instruction = typed_instruction.instruction

          case instruction.type
          when :push_int
            stack << LLVM.Int(instruction.arg)
          when :set_var
            var = vars[instruction.arg] = builder.alloca(LLVM::Int32)
            builder.store(stack.pop, var)
          when :push_var
            var = vars[instruction.arg]
            builder.ret(builder.load(var))
          else
            raise "unknown JIT instruction: #{instruction.inspect}"
          end

          index += 1
        end
      end
    end
    @module.verify
    # @module.dump # debug IR
    engine = LLVM::JITCompiler.new(@module)
    engine.run_function(@module.functions['main'])
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
end
