require_relative './spec_helper'

describe 'VM' do
  def run_vm(code)
    VM.new(code).run
  end

  it 'can set and get variables' do
    expect(run_vm('x = 1; x')).must_equal 1
  end

  it 'can define and call methods' do
    code = <<~CODE
      def foo(x, y); x + 1; end
      foo(2, 100)
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
