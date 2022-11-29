require 'set'

# unification algorithm ported from https://eli.thegreenplace.net/2018/unification/

class Term
end

class App < Term
  def initialize(fname, args = [])
    super()
    @fname = fname
    @args = args
  end

  attr_reader :fname, :args

  def ==(other)
    other.is_a?(App) && other.fname == @fname && other.args == @args
  end
end

class Var < Term
  def initialize(name)
    super()
    @name = name
  end

  attr_reader :name

  def ==(other)
    other.is_a?(Var) && other.name == @name
  end
end

class Const < Term
  def initialize(value)
    super()
    @value = value
  end

  attr_reader :value

  def ==(other)
    other.is_a?(Const) && other.value == @value
  end
end

def unify(x, y, subst = {})
  return if subst.nil?

  if x == y
    subst
  elsif x.is_a?(Var)
    unify_variable(x, y, subst)
  elsif y.is_a?(Var)
    unify_variable(y, x, subst)
  elsif x.is_a?(App) && y.is_a?(App)
    return if x.fname != y.fname || x.args.size != y.args.size

    x.args.each_with_index do |arg, i|
      subst = unify(arg, y.args[i], subst)
    end

    subst
  else
    nil
  end
end

def unify_variable(v, x, subst)
  raise 'bad variable' unless v.is_a?(Var)

  if subst[v.name]
    unify(subst[v.name], x, subst)
  elsif x.is_a?(Var) && subst[x.name]
    unify(v, subst[x.name], subst)
  elsif occurs_check(v, x, subst)
    nil
  else
    # v is not yet in subst and can't simplify x. Extend subst.
    subst.update(v.name => x)
  end
end

def occurs_check(v, term, subst)
  raise 'bad variable' unless v.is_a?(Var)

  if v == term
    true
  elsif term.is_a?(Var) && subst[term.name]
    occurs_check(v, subst[term.name], subst)
  elsif term.is_a?(App)
    term.args.any? do |arg|
      occurs_check(v, arg, subst)
    end
  else
    false
  end
end

class InferenceEngine
  class TypedInstruction
    def initialize(instruction:, engine:)
      @instruction = instruction
      @engine = engine
    end

    attr_reader :instruction

    attr_accessor :type

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

  def initialize(instructions, code:)
    @code = code
    @typed_instructions = instructions.map do |instruction|
      TypedInstruction.new(instruction: instruction, engine: self)
    end
    @scope = [{ vars: {}, stack: [] }]
    @methods = {}
    @constants = {}
    @callers = {}
    @if_stack = []
  end

  def infer
    build_type_variables
    build_substitution
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

  def build_type_variables
    @typed_instructions.each do |instruction|
    end
  end

  def build_substitution
  end
end
