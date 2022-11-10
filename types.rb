require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'natalie_parser'
  gem 'minitest'
  gem 'minitest-focus'
end

require 'natalie_parser'
require 'minitest/spec'
require 'minitest/autorun'

class Object
  def not_nil!
    self
  end
end

class NilClass
  def not_nil!
    raise 'nil!'
  end
end

class Compiler
  class Instruction
    def initialize(type, node:, arg: nil, extra_arg: nil)
      @type = type
      @node = node
      raise 'bad node' unless @node.is_a?(Sexp)
      @arg = arg
      @extra_arg = extra_arg
    end

    attr_reader :type, :node, :arg, :extra_arg

    def to_a
      [type, arg, extra_arg].compact
    end
  end

  def initialize(code)
    @ast = NatalieParser.parse(code)
    @ast = s(:block, @ast) if @ast.sexp_type != :block
    @out = []
  end

  def compile
    transform(@ast)
    @out
  end

  private

  def transform(node)
    case node.sexp_type
    when :block
      node[1..].each { |n| transform(n) }
    when :call
      _, receiver, op, *args = node
      if receiver
        transform(receiver)
      else
        @out << Instruction.new(:push_nil, node: node)
      end
      args.each { |a| transform(a) }
      @out << Instruction.new(:send, node: node, arg: op, extra_arg: args.size)
    when :defn
      _, name, args, *body = node
      @out << Instruction.new(:def, node: node, arg: name)
      args[1..].each_with_index do |arg, index|
        @out << Instruction.new(:push_arg, node: args, arg: index)
        @out << Instruction.new(:set_var, node: args, arg: arg)
      end
      body.each { |n| transform(n) }
      @out << Instruction.new(:end_def, node: node, arg: name)
    when :if
      _, condition, true_body, false_body = node
      transform(condition)
      @out << Instruction.new(:if, node: node)
      transform(true_body)
      @out << Instruction.new(:else, node: node)
      transform(false_body)
      @out << Instruction.new(:end_if, node: node)
    when :lasgn
      _, name, value = node
      transform(value)
      @out << Instruction.new(:set_var, node: node, arg: name)
    when :lvar
      @out << Instruction.new(:push_var, node: node, arg: node[1])
    when :lit
      @out << Instruction.new(:push_int, node: node, arg: node[1])
    when :str
      @out << Instruction.new(:push_str, node: node, arg: node[1])
    when :nil
      @out << Instruction.new(:push_nil, node: node)
    else
      raise "unknown node: #{node.inspect}"
    end
  end
end

describe 'Compiler' do
  def compile(code, native: false)
    instructions = Compiler.new(code).compile
    if native
      instructions
    else
      instructions.map(&:to_a)
    end
  end

  it 'compiles literals' do
    expect(compile('1')).must_equal [[:push_int, 1]]
    expect(compile('"foo"')).must_equal [[:push_str, 'foo']]
  end

  it 'compiles variables' do
    expect(compile('x = 1; x')).must_equal [
      [:push_int, 1],
      [:set_var, :x],
      [:push_var, :x]
    ]
  end

  it 'compiles method definitions' do
    expect(compile('def foo; 1; end')).must_equal [
      [:def, :foo],
      [:push_int, 1],
      [:end_def, :foo]
    ]
    expect(compile('def foo(x, y); x; end')).must_equal [
      [:def, :foo],
      [:push_arg, 0],
      [:set_var, :x],
      [:push_arg, 1],
      [:set_var, :y],
      [:push_var, :x],
      [:end_def, :foo]
    ]
  end

  it 'compiles method calls' do
    expect(compile('3 + 4')).must_equal [
      [:push_int, 3],
      [:push_int, 4],
      [:send, :+, 1] # 1 arg
    ]
    expect(compile('"foo" + "bar"')).must_equal [
      [:push_str, 'foo'],
      [:push_str, 'bar'],
      [:send, :+, 1]
    ]
    expect(compile('foo(1, "bar")')).must_equal [
      [:push_nil],
      [:push_int, 1],
      [:push_str, 'bar'],
      [:send, :foo, 2]
    ]
    expect(compile('x=1; x.bar(3)')).must_equal [
      [:push_int, 1],
      [:set_var, :x],
      [:push_var, :x],
      [:push_int, 3],
      [:send, :bar, 1]
    ]
  end

  it 'compiles if expressions' do
    expect(compile('if foo; "foo"; else; "bar"; end')).must_equal [
      [:push_nil],
      [:send, :foo, 0],
      [:if],
      [:push_str, 'foo'],
      [:else],
      [:push_str, 'bar'],
      [:end_if]
    ]
  end
end

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
        @callers[method_name].each do |send_ti|
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

describe 'TypeInferrer' do
  def infer(code)
    instructions = Compiler.new(code).compile
    TypeInferrer.new(instructions, code: code).infer.map do |typed_instruction|
      {
        type: typed_instruction.type,
        instruction: typed_instruction.instruction.to_a
      }
    end
  end

  it 'works' do
    code = <<-CODE
      def bar; foo; end
      def baz; bar; end
      x = baz
      def foo; 1; end
    CODE
    expect(infer(code)).must_equal [
      { type: :int, instruction: [:def, :bar] },
      { type: :nil, instruction: [:push_nil] },
      { type: :int, instruction: [:send, :foo, 0] },
      { type: :nil, instruction: [:end_def, :bar] },
      { type: :int, instruction: [:def, :baz] },
      { type: :nil, instruction: [:push_nil] },
      { type: :int, instruction: [:send, :bar, 0] },
      { type: :nil, instruction: [:end_def, :baz] },
      { type: :nil, instruction: [:push_nil] },
      { type: :int, instruction: [:send, :baz, 0] },
      { type: :int, instruction: [:set_var, :x] },
      { type: :int, instruction: [:def, :foo] },
      { type: :int, instruction: [:push_int, 1] },
      { type: :nil, instruction: [:end_def, :foo] }
    ]
  end

  it 'infers the type of a variable' do
    expect(infer('x = 1; x')).must_equal [
      { type: :int, instruction: [:push_int, 1] },
      { type: :int, instruction: [:set_var, :x] },
      { type: :int, instruction: [:push_var, :x] }
    ]
  end

  it 'raises an error if a variable type changes' do
    expect do
      infer('x = 10; x = "foo"')
    end.must_raise TypeError
  end

  it 'infers the types of method arguments' do
    expect(infer('def foo(x, y); x; end; foo(10, "hi")')).must_equal [
      { type: :int, instruction: [:def, :foo] },
      { type: :int, instruction: [:push_arg, 0] },
      { type: :int, instruction: [:set_var, :x] },
      { type: :str, instruction: [:push_arg, 1] },
      { type: :str, instruction: [:set_var, :y] },
      { type: :int, instruction: [:push_var, :x] },
      { type: :nil, instruction: [:end_def, :foo] },
      { type: :nil, instruction: [:push_nil] },
      { type: :int, instruction: [:push_int, 10] },
      { type: :str, instruction: [:push_str, 'hi'] },
      { type: :int, instruction: [:send, :foo, 2] }
    ]
  end

  it 'infers the type of a built-in math operation' do
    expect(infer('1 + 2')).must_equal [
      { type: :int, instruction: [:push_int, 1] },
      { type: :int, instruction: [:push_int, 2] },
      { type: :int, instruction: [:send, :+, 1] }
    ]
  end

  it 'infers the type of a built-in string operation' do
    expect(infer('"foo" + "bar"')).must_equal [
      { type: :str, instruction: [:push_str, 'foo'] },
      { type: :str, instruction: [:push_str, 'bar'] },
      { type: :str, instruction: [:send, :+, 1] }
    ]
  end

  it 'infers the type of a built-in math operation where the receiver is not immediately known' do
    expect(infer('def plus(x); x + 1; end; plus(2)')).must_equal [
      { type: :int, instruction: [:def, :plus] },
      { type: :int, instruction: [:push_arg, 0] },
      { type: :int, instruction: [:set_var, :x] },
      { type: :int, instruction: [:push_var, :x] },
      { type: :int, instruction: [:push_int, 1] },
      { type: :int, instruction: [:send, :+, 1] },
      { type: :nil, instruction: [:end_def, :plus] },
      { type: :nil, instruction: [:push_nil] },
      { type: :int, instruction: [:push_int, 2] },
      { type: :int, instruction: [:send, :plus, 1] }
    ]
  end

  it 'infers the return type of a method and a method call' do
    expect(infer('def foo; "hi"; end; foo')).must_equal [
      { type: :str, instruction: [:def, :foo] },
      { type: :str, instruction: [:push_str, 'hi'] },
      { type: :nil, instruction: [:end_def, :foo] },
      { type: :nil, instruction: [:push_nil] },
      { type: :str, instruction: [:send, :foo, 0] }
    ]
  end

  it 'raises an error if a method arg type changes' do
    expect do
      infer("def foo(x); x; end\n\nfoo(10)\nfoo('hi')")
    end.must_raise TypeError
  end

  it 'infers the return type of an if expression' do
    code = <<~CODE
      if 1
        'foo'
      else
        if 2
          'bar'
        else
          'baz'
        end
      end
    CODE
    expect(infer(code)).must_equal [
      { type: :int, instruction: [:push_int, 1] },
      { type: :str, instruction: [:if] },
      { type: :str, instruction: [:push_str, 'foo'] },
      { type: :nil, instruction: [:else] },
      { type: :int, instruction: [:push_int, 2] },
      { type: :str, instruction: [:if] },
      { type: :str, instruction: [:push_str, 'bar'] },
      { type: :nil, instruction: [:else] },
      { type: :str, instruction: [:push_str, 'baz'] },
      { type: :nil, instruction: [:end_if] },
      { type: :nil, instruction: [:end_if] }
    ]
  end

  it 'raises an error if the return type of both branches an if expression do not match' do
    code = <<~CODE
      if 1
        "foo"
      else
        10
      end
    CODE
    expect do
      infer(code)
    end.must_raise TypeError
  end
end

class VM
  def initialize(code)
    @code = code
    @instructions = Compiler.new(code).compile
    @typed_instructions = TypeInferrer.new(@instructions, code: code).infer
    @scope = [{ vars: {}, stack: [] }]
    @methods = {}
  end

  def run
    index = 0
    while index < @typed_instructions.size
      typed_instruction = @typed_instructions[index]
      instruction = typed_instruction.instruction

      case instruction.type
      when :push_int
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

describe 'VM' do
  def run_vm(code)
    VM.new(code).run
  end

  it 'can set and get variables' do
    expect(run_vm('x = 1; x')).must_equal 1
  end

  it 'can define and call methods' do
    code = <<~CODE
      def foo(x); x + 1; end
      foo(2)
    CODE
    expect(run_vm(code)).must_equal 3
  end

  it 'can branch with if' do
    code = <<~CODE
      if nil
        if 1
          2
        else
          3
        end
      else     # <-- take this branch
        if 4
          5    # <-- final result
        else
          6
        end
      end
    CODE
    expect(run_vm(code)).must_equal 5
  end
end
