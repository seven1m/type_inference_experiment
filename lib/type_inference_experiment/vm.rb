class VM
  def initialize(code)
    @code = code
    @instructions = Compiler.new(code).compile
    @typed_instructions = InferenceEngine.new(@instructions, code: code).infer
    @scope = [{ vars: {}, stack: [] }]
    @methods = {}
  end

  def run
    index = 0
    while index < @typed_instructions.size
      typed_instruction = @typed_instructions[index]
      instruction = typed_instruction.instruction

      case instruction.type
      when :push_int, :push_str
        stack << instruction.arg
      when :set_var
        vars[instruction.arg] = stack.pop
      when :push_var
        stack.push(vars[instruction.arg])
      when :def
        @methods[instruction.arg] = index + 1
        index += 1 until @typed_instructions[index].instruction.type == :end_def
      when :end_def
        frame = @scope.pop
        stack << frame[:stack].pop
        index = frame[:return]
      when :push_nil
        stack << nil
      when :send
        args = []
        instruction.extra_arg.times { args << stack.pop }
        receiver = stack.pop
        name = instruction.arg
        if receiver
          unless receiver.respond_to?(name)
            raise MethodError, "#{receiver.class} has no method `#{name}'"
          end
          stack << receiver.send(name, *args)
        else
          @scope << { vars: {}, stack: [], return: index, args: args }
          index = @methods.fetch(name)
          next
        end
      when :push_arg
        stack << args.pop
      when :if
        condition = stack.pop
        depth = 0
        unless condition
          index += 1
          until depth.zero? && @typed_instructions[index].instruction.type == :else
            case @typed_instructions[index].instruction.type
            when :if
              depth += 1
            when :end_if
              depth -= 1
            end
            index += 1
          end
        end
      when :else
        depth = 0
        index += 1
        until depth.zero? && @typed_instructions[index].instruction.type == :end_if
          case @typed_instructions[index].instruction.type
          when :if
            depth += 1
          when :end_if
            depth -= 1
          end
          index += 1
        end
      when :end_if
        :noop
      else
        raise "unknown VM instruction: #{instruction.inspect}"
      end

      index += 1
    end
    stack.last
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
