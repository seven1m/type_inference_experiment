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
      @out << [:push_def, name]
      args[1..].reverse_each { |a| @out << [:set_var, a] }
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
      [:push_def, :foo],
      [:push_int, 1],
      [:end_def, :foo]
    ]
    expect(compile('def foo(x); x; end')).must_equal [
      [:push_def, :foo],
      [:set_var, :x],
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
    @instructions = instructions
    @scope = [{ vars: {}, type_stack: [] }]
    @methods = {}
  end

  def infer
    @pass = 1
    walk(@instructions)
    @pass = 2
    walk(@instructions)
    @instructions
  end

  private

  def walk(instructions)
    index = 0
    while index < instructions.size
      instruction = instructions[index]

      case instruction.first
      when :if
        index += 1
        true_body = []
        until instructions[index].first == :else
          true_body << instructions[index]
          index += 1
        end
        index += 1
        false_body = []
        until instructions[index].first == :end_if
          false_body << instructions[index]
          index += 1
        end
        walk(true_body)
        true_return_type = type_stack.pop
        walk(false_body)
        false_return_type = type_stack.pop
        if true_return_type != false_return_type
          raise TypeError, "Both if branches must match! (got: #{true_return_type}, #{false_return_type})"
        end
        instruction[1] = true_return_type
      when :push_int
        type_stack << :int
      when :push_nil
        type_stack << :nil
      when :push_str
        type_stack << :str
      when :push_def
        name = instruction[1]
        unless (method = @methods[name])
          method_scope = { vars: {}, type_stack: [] }
          method = { name: name, scope: method_scope, instruction: instruction }
          @methods[name] = method
        end
        body = []
        index += 1
        until instructions[index].first == :end_def
          body << instructions[index]
          index += 1
        end
        method[:body] = body
      when :push_var
        name = instruction[1]
        type = if (var = vars[name])
                 var[:type]
               else
                 :unkown
               end
        instruction[2] = type
        type_stack << type
      when :send
        _, message, arg_count = instruction
        if @pass == 2
          return_type = walk_method(message, args: type_stack.pop(arg_count))
          instruction[3] = return_type
        end
      when :set_var
        name = instruction[1]
        type = type_stack.pop
        if type
          if (var = vars[name])
            assert_type(type, var)
          else
            var = { name: name, type: type }
            vars[name] = var
          end
          instruction[2] = type
        else
          instruction[2] = :unknown
        end
      else
        raise "unkown instruction: #{instruction.first.inspect}"
      end

      index += 1
    end
  end

  def walk_method(message, args:)
    unless (method = @methods[message])
      raise TypeError, "Method not defined: #{message}"
    end

    @scope << method.fetch(:scope)
    method[:scope][:type_stack] = args

    walk(method.fetch(:body))

    if type_stack.size != 1
      raise "Bad compile? Method type stack at the end of #{method[:name]}: #{type_stack.inspect}"
    end

    method[:instruction][2] = method[:return_type] = type_stack.pop
    @scope.pop

    method[:return_type]
  end

  def vars
    @scope.last.fetch(:vars)
  end

  def type_stack
    @scope.last.fetch(:type_stack)
  end

  def assert_type(type, var)
    return if var[:type] == type

    raise TypeError, "Variable #{var[:name]} has type #{var[:type]}, not #{type}."
  end
end

describe 'TypeInferrer' do
  def infer(code)
    instructions = Compiler.new(code).compile
    TypeInferrer.new(instructions).infer
  end

  it 'infers the type of a variable' do
    expect(infer('x = 1; x')).must_equal [
      [:push_int, 1],
      [:set_var, :x, :int],
      [:push_var, :x, :int]
    ]
  end

  it 'infers the types of method arguments' do
    expect(infer('def foo(x, y); x; end; foo(10, "hi")')).must_equal [
      [:push_def, :foo, :int],
      [:set_var, :y, :str],
      [:set_var, :x, :int],
      [:push_var, :x, :int],
      [:end_def, :foo],
      [:push_nil],
      [:push_int, 10],
      [:push_str, 'hi'],
      [:send, :foo, 2, :int]
    ]
  end

  it 'infers the return type of a method and a method call' do
    expect(infer('def foo; "hi"; end; foo')).must_equal [
      [:push_def, :foo, :str],
      [:push_str, 'hi'],
      [:end_def, :foo],
      [:push_nil],
      [:send, :foo, 0, :str]
    ]
  end

  it 'raises an error if a method arg type changes' do
    e = expect do
      infer('def foo(x); x; end; foo(10); foo("hi")')
    end.must_raise TypeError
    expect(e.message).must_equal 'Variable x has type int, not str.'
  end

  it 'infers the return type of an if expression' do
    expect(infer('def foo; 1; end; if foo; "foo"; else; "bar"; end')).must_equal [
      [:push_def, :foo, :int],
      [:push_int, 1],
      [:end_def, :foo],
      [:push_nil],
      [:send, :foo, 0, :int],
      [:if, :str],
      [:push_str, 'foo'],
      [:else],
      [:push_str, 'bar'],
      [:end_if]
    ]
  end

  it 'raises an error if the return type of both branches an if expression do not match' do
    e = expect do
      infer('def foo; 1; end; if foo; "foo"; else; 10; end')
    end.must_raise TypeError
    expect(e.message).must_equal 'Both if branches must match! (got: str, int)'
  end
end
