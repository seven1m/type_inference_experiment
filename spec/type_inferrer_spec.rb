require_relative './spec_helper'

describe 'InferenceEngine' do
  def infer(code)
    instructions = Compiler.new(code).compile
    InferenceEngine.new(instructions, code: code).infer.map do |typed_instruction|
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
