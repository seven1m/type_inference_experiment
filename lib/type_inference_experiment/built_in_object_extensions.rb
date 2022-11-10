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
