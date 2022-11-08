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
    return @out << [:push_nil] if node.nil?

    case node.sexp_type
    when :block
      node[1..].each { |n| transform(n) }
    when :call
      _, receiver, op, *args = node
      transform(receiver)
      args.each { |a| transform(a) }
      @out << [:send, op, args.size]
    when :defn
      _, name, args, *body = node
      @out << [:def, name]
      args[1..].each_with_index do |arg, index|
        @out << [:push_arg, index]
        @out << [:set_var, arg]
      end
      body.each { |n| transform(n) }
      @out << [:end_def, name]
    when :if
      _, condition, true_body, false_body = node
      transform(condition)
      @out << [:if]
      transform(true_body)
      @out << [:else]
      transform(false_body)
      @out << [:end_if]
    when :lasgn
      _, name, value = node
      transform(value)
      @out << [:set_var, name]
    when :lvar
      @out << [:push_var, node[1]]
    when :lit
      @out << [:push_int, node[1]]
    when :str
      @out << [:push_str, node[1]]
    else
      raise "unknown node: #{node.inspect}"
    end
  end
end

describe 'Compiler' do
  def compile(code)
    Compiler.new(code).compile
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
  def initialize(instructions)
    @instructions_meta = instructions.each_with_index.map do |instruction, index|
      {
        index: index,
        instruction: instruction,
        dependencies: [],
        type: nil
      }
    end
    @scope = [{ vars: {}, type_stack: [] }]
    @methods = {}
    @callers = {}
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

  def find_type(meta, seen = Set.new)
    return meta[:type] if meta[:type]

    if seen.include?(meta)
      raise TypeError, "Could not determine type of #{meta.inspect}"
    end

    seen << meta

    possibles = meta[:dependencies].map do |dependency|
      find_type(dependency, seen)
    end.uniq

    case possibles.size
    when 0
      nil
    when 1
      possibles.first
    else
      raise TypeError, "Could not determine type of #{meta.inspect}; could be one of: #{possibles.inspect}"
    end
  end

  def find_methods
    @instructions_meta.each_with_index do |meta, index|
      case meta[:instruction].first
      when :def
        _, name = meta[:instruction]
        @methods[name] = meta
      when :send
        _, name, arg_count = meta[:instruction]
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

      case instruction.first
      when :def
        _, name = instruction
        @scope << { vars: {}, type_stack: [] }
        @method = meta
      when :end_def
        @method[:dependencies] << @instructions_meta[index - 1]
        @method = nil
        @scope.pop
        meta[:type] = :nil
      when :push_nil
        meta[:type] = :nil
      when :push_int
        meta[:type] = :int
      when :push_str
        meta[:type] = :str
      when :send
        _, name, _arg_count = instruction
        meta[:dependencies] << @methods[name]
      when :set_var
        _, name = instruction
        meta[:dependencies] << @instructions_meta[index - 1]
        @scope.last[:vars][name] = meta
      when :push_var
        _, name = instruction
        meta[:dependencies] << @scope.last[:vars].fetch(name)
      when :push_arg
        _, arg_index = instruction
        method_meta = @instructions_meta[..(index - 1)].reverse.detect do |m|
          m[:instruction].first == :def
        end
        raise "Could not find def to go with #{instruction.inspect}" if method_meta.nil?
        @callers[method_meta[:instruction][1]].each do |send_meta|
          meta[:dependencies] << send_meta[:send_args][arg_index]
        end
      else
        raise "unknown instruction: #{instruction}"
      end

      index += 1
    end
  end
end

describe 'TypeInferrer' do
  def infer(code)
    instructions = Compiler.new(code).compile
    TypeInferrer.new(instructions).infer
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
    e = expect do
      infer('def foo(x); x; end; foo(10); foo("hi")')
    end.must_raise TypeError
  end

  #it 'infers the return type of an if expression' do
    #expect(infer('def foo; 1; end; if foo; "foo"; else; "bar"; end')).must_equal [
      #{ type: :int, instruction: [:def, :foo] },
      #{ type: :int, instruction: [:push_int, 1] },
      #{ type: :nil, instruction: [:end_def, :foo] },
      #{ type: :nil, instruction: [:push_nil] },
      #{ type: :int, instruction: [:send, :foo, 0] },
      #{ type: :str, instruction: [:if] },
      #{ type: :str, instruction: [:push_str, 'foo'] },
      #{ type: :nil, instruction: [:else] },
      #{ type: :str, instruction: [:push_str, 'bar'] },
      #{ type: :nil, instruction: [:end_if] }
    #]
  #end

  #it 'raises an error if the return type of both branches an if expression do not match' do
    #e = expect do
      #infer('def foo; 1; end; if foo; "foo"; else; 10; end')
    #end.must_raise TypeError
    #expect(e.message).must_equal 'Both if branches must match! (got: str, int)'
  #end
end
