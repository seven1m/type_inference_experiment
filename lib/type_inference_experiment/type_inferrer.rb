require 'set'

class TypeInferrer
  class TypedInstruction
    def initialize(instruction:, type_inferrer:)
      @instruction = instruction
      @type_inferrer = type_inferrer
      @dependencies = []
    end

    attr_reader :instruction, :dependencies

    attr_accessor :type, :send_args

    def add_dependency(dependency)
      dependencies << dependency
    end

    def type!(seen = Set.new)
      return @type if @type

      if seen.include?(self)
        raise TypeError, "Could not determine type of #{inspect}"
      end
      seen << self

      possibles = dependencies.map do |dependency|
        [dependency, dependency.type!(seen)]
      end

      possibles.uniq! { |_, t| t }

      if possibles.size == 1
        @type = possibles.first[1]
        return @type
      end

      @type_inferrer.raise_type_error(
        instruction: instruction,
        possibles: possibles
      )
    end

    def to_h
      {
        type: type,
        instruction: instruction
      }
    end

    def inspect
      "#TypedInstruction<#{to_h}>"
    end
  end

  class MethodDependency
    BUILT_INS = {
      int: {
        '+': :int,
        '-': :int,
        '*': :int,
        '/': :int
      },
      str: {
        '+': :str
      }
    }.freeze

    def initialize(receiver:, typed_instruction:, type_inferrer:)
      @receiver = receiver
      @typed_instruction = typed_instruction
      @type_inferrer = type_inferrer
    end

    def type!(seen = Set.new)
      receiver_type = @receiver.type!

      if seen.include?(self)
        raise TypeError, "Could not determine type of #{inspect}"
      end
      seen << self

      if (type = BUILT_INS.dig(receiver_type, @typed_instruction.instruction.arg))
        @typed_instruction.type = type
        return type
      end

      @type_inferrer.raise_type_error(
        instruction: @typed_instruction.instruction,
        possibles: []
      )
    end
  end

  def initialize(instructions, code:)
    @code = code
    @typed_instructions = instructions.map do |instruction|
      TypedInstruction.new(instruction: instruction, type_inferrer: self)
    end
    @scope = [{ vars: {}, stack: [] }]
    @methods = {}
    @callers = {}
    @if_stack = []
  end

  def infer
    find_methods
    find_dependencies
    @typed_instructions.each(&:type!)
    @typed_instructions
  end

  def raise_type_error(instruction:, possibles:)
    node = instruction.node
    thing = if node.sexp_type == :args
              "`#{node[1]}' argument"
            else
              "`#{node.sexp_type}' expression"
            end
    message = "Could not determine type of #{thing} on line #{node.line}\n\n"

    if possibles.any?
      message << "Could be one of: #{possibles.map(&:last).inspect}\n\n"
    end

    message << "  #{@code.split(/\n/)[node.line - 1]}\n"
    message << "#{' ' * (node.column + 1)}^ expression here\n\n"

    possibles.each_with_index do |(dependency, type), index|
      instruction = dependency.instruction
      node = instruction.node
      message << "Possibility #{index + 1} (line #{node.line}):\n\n"
      message << "  #{@code.split(/\n/)[node.line - 1]}\n" \
                 "#{' ' * (node.column + 1)}^ #{type}\n\n"
    end

    raise TypeError, message
  end

  private

  def find_methods
    @typed_instructions.each_with_index do |ti, index|
      case ti.instruction.type
      when :def
        name = ti.instruction.arg
        @methods[name] = ti
      when :send
        name = ti.instruction.arg
        arg_count = ti.instruction.extra_arg
        ti.send_args = (0...arg_count).map { |i| @typed_instructions[index - 1 - i] }.reverse
        (@callers[name] ||= []) << ti
      end
    end
  end

  def find_dependencies
    index = 0
    while index < @typed_instructions.size
      ti = @typed_instructions[index]

      instruction = ti.instruction

      case instruction.type

      when :def
        name = instruction.arg
        @scope << { vars: {}, stack: [] }
        @method = ti

      when :end_def
        result = stack.pop.not_nil!
        @method.add_dependency(result.not_nil!)
        @method = nil
        @scope.pop
        ti.type = :nil
        stack << result

      when :push_nil
        ti.type = :nil
        stack << ti

      when :push_int
        ti.type = :int
        stack << ti

      when :push_str
        ti.type = :str
        stack << ti

      when :send
        name = instruction.arg
        instruction.extra_arg.times { stack.pop } # discard args
        receiver = stack.pop
        if receiver.type == :nil
          ti.add_dependency(@methods.fetch(name))
        else
          ti.add_dependency(MethodDependency.new(receiver: receiver, typed_instruction: ti, type_inferrer: self))
        end
        stack << ti

      when :set_var
        name = instruction.arg
        if (existing = vars[name])
          existing.dependencies.each do |dependency|
            ti.add_dependency(dependency)
          end
        else
          vars[name] = ti
        end
        ti.add_dependency(stack.pop.not_nil!)

      when :push_var
        name = instruction.arg
        ti.add_dependency(vars.fetch(name))
        stack << ti

      when :push_arg
        arg_index = instruction.arg

        # first find the :def instruction above this arg
        method_ti = @typed_instructions[..(index - 1)].reverse.detect do |m|
          m.instruction.type == :def
        end
        raise "Could not find def to go with #{instruction.inspect}" if method_ti.nil?

        # find all the callers of this method and mark them as dependencies for this arg
        method_name = method_ti.instruction.arg
        (@callers[method_name] || []).each do |send_ti|
          ti.add_dependency(send_ti.send_args[arg_index])
        end

        stack << ti

      when :if
        stack.pop.not_nil! # condition can be ignored
        @if_stack << ti

      when :else
        ti.type = :nil
        @if_stack.last.add_dependency(stack.pop.not_nil!)

      when :end_if
        ti.type = :nil
        @if_stack.last.add_dependency(stack.pop.not_nil!)
        stack << @if_stack.pop

      else
        raise "unknown instruction: #{instruction}"

      end

      index += 1
    end
  end

  def vars
    @scope.last.fetch(:vars)
  end

  def stack
    @scope.last.fetch(:stack)
  end
end