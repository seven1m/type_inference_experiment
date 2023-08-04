require_relative './spec_helper'

describe 'JIT' do
  def run_jit(code)
    JIT.new(code).run
  end

  it 'can return an int' do
    expect(run_jit('1')).must_equal 1
  end

  it 'can return a str' do
    expect(run_jit('"hello"')).must_equal 'hello'
  end

  it 'can set and get a variable with an int' do
    expect(run_jit('x = 1; x')).must_equal 1
  end

  it 'can set and get a variable with a str' do
    expect(run_jit('x = "hello"; x')).must_equal 'hello'
  end

  it 'can define and call methods' do
    code = <<~CODE
      def foo(x); x + 1; end
      foo(2)
    CODE
    expect(run_jit(code)).must_equal 3
  end

  #it 'can branch with if' do
    #code = <<~CODE
      #if nil
        #if 1
          #2
        #else
          #3
        #end
      #else     # <-- take this branch
        #if 4
          #5    # <-- final result
        #else
          #6
        #end
      #end
    #CODE
    #expect(run_vm(code)).must_equal 5
  #end
end
