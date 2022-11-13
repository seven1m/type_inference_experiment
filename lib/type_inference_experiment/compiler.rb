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

    def inspect
      "#<Compiler::Instruction type=#{type.inspect} arg=#{arg.inspect} extra_arg=#{extra_arg.inspect}>"
    end

    def to_s
      inspect
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
    when :class
      _, name, _superclass, *body = node
      @out << Instruction.new(:class, node: node, arg: name)
      body.each { |n| transform(n) }
      @out << Instruction.new(:end_class, node: node, arg: name)
    when :const
      @out << Instruction.new(:push_const, node: node, arg: node[1])
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
