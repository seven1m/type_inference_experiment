require_relative './spec_helper'

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
