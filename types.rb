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
  def initialize(instructions, code:)
    @instructions_meta = instructions.each_with_index.map do |instruction, index|
      {
        index: index,
        instruction: instruction,
        dependencies: [],
        type: nil
      }
    end
    @code = code
    @scope = [{ vars: {}, stack: [] }]
    @methods = {}
    @callers = {}
    @if_stack = []
  end

  def infer
    find_methods
    find_dependencies
    @instructions_meta.each do |meta|
      next if meta[:type]
      meta[:type] = find_type(meta)
    end
    @instructions_meta.map do |meta|
      meta.slice(:type, :instruction)
    end
  end

  private

  # NOTE: This could be more efficient by caching the type as it returns
  # back up the call stack.
  def find_type(meta, seen = Set.new)
    return meta[:type] if meta[:type]

    if seen.include?(meta)
      raise TypeError, "Could not determine type of #{meta.inspect}"
    end

    seen << meta

    possibles = meta[:dependencies].map do |dependency|
      [dependency, find_type(dependency, seen)]
    end.uniq { |_, t| t }

    if possibles.size == 1
      possibles.first[1]
    else
      instruction = meta.fetch(:instruction)
      node = instruction.node
      message = "Could not determine type of `#{node.sexp_type}' expression on line #{node.line}\n" \
                "Could be one of: #{possibles.map(&:last).inspect}\n\n" \
                "  #{@code.split(/\n/)[node.line - 1]}\n" \
                "#{' ' * (node.column + 1)}^ here\n\n"
      possibles.each_with_index do |(dependency, type), index|
        instruction = dependency.fetch(:instruction)
        message << "Possibility #{index + 1} (line #{instruction.node.line}):\n\n"
        message << "  #{@code.split(/\n/)[instruction.node.line - 1]}\n" \
                   "#{' ' * (instruction.node.column + 1)}^ #{type}\n\n"
      end
      raise TypeError, message
    end
  end

  def find_methods
    @instructions_meta.each_with_index do |meta, index|
      case meta[:instruction].type
      when :def
        name = meta[:instruction].arg
        @methods[name] = meta
      when :send
        name = meta[:instruction].arg
        arg_count = meta[:instruction].extra_arg
        meta[:send_args] = (0...arg_count).map { |i| @instructions_meta[index - 1 - i] }.reverse
        (@callers[name] ||= []) << meta
      end
    end
  end

  def find_dependencies
    index = 0
    while index < @instructions_meta.size
      meta = @instructions_meta[index]

      instruction = meta.fetch(:instruction)

      case instruction.type

      when :def
        name = instruction.arg
        @scope << { vars: {}, stack: [] }
        @method = meta

      when :end_def
        result = stack.pop
        @method[:dependencies] << result
        @method = nil
        @scope.pop
        meta[:type] = :nil
        stack << result

      when :push_nil
        meta[:type] = :nil
        stack << meta

      when :push_int
        meta[:type] = :int
        stack << meta

      when :push_str
        meta[:type] = :str
        stack << meta

      when :send
        name = instruction.arg
        meta[:dependencies] << @methods[name]
        stack << meta

      when :set_var
        name = instruction.arg
        if (existing = vars[name])
          meta[:dependencies] += existing[:dependencies]
        else
          vars[name] = meta
        end
        meta[:dependencies] << stack.pop

      when :push_var
        name = instruction.arg
        meta[:dependencies] << vars.fetch(name)
        stack << meta

      when :push_arg
        arg_index = instruction.arg

        # first find the :def instruction above this arg
        method_meta = @instructions_meta[..(index - 1)].reverse.detect do |m|
          m[:instruction].type == :def
        end
        raise "Could not find def to go with #{instruction.inspect}" if method_meta.nil?

        # find all the callers of this method and mark them as dependencies for this arg
        method_name = method_meta[:instruction].arg
        @callers[method_name].each do |send_meta|
          meta[:dependencies] << send_meta[:send_args][arg_index]
        end

        stack << meta

      when :if
        stack.pop # condition can be ignored
        @if_stack << meta

      when :else
        meta[:type] = :nil
        @if_stack.last[:dependencies] << stack.pop

      when :end_if
        meta[:type] = :nil
        @if_stack.last[:dependencies] << stack.pop
        @if_stack.pop

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
    TypeInferrer.new(instructions, code: code).infer.map do |meta|
      meta.update(
        instruction: meta[:instruction].to_a
      )
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
      infer('def foo(x); x; end; foo(10); foo("hi")')
    end.must_raise TypeError
  end

  it 'infers the return type of an if expression' do
    expect(infer('def foo; 1; end; if foo; "foo"; else; "bar"; end')).must_equal [
      { type: :int, instruction: [:def, :foo] },
      { type: :int, instruction: [:push_int, 1] },
      { type: :nil, instruction: [:end_def, :foo] },
      { type: :nil, instruction: [:push_nil] },
      { type: :int, instruction: [:send, :foo, 0] },
      { type: :str, instruction: [:if] },
      { type: :str, instruction: [:push_str, 'foo'] },
      { type: :nil, instruction: [:else] },
      { type: :str, instruction: [:push_str, 'bar'] },
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
