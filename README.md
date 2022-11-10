# Type Inference Experiment

I wanted to play around with a language with static types and type inference
and answer some questions:

- How do we keep track of the type?
- How do we infer a type if none is given?
- How do we infer a type of a built-in method if it exists on more than one class/type?

**This is my playground.**

## Usage

Most of the goodies are in the specs, but there's also a goofy little
binary you can run:

```sh
bin/tie -e "x = 1; x + 2"

3
```

But the beauty is when you don't give the inference engine enough information
to determine a type:

```sh
bin/tie -e "def foo(x); x; end"

Could not determine type of `x' argument on line 1 (TypeError)

  def foo(x); x; end
  ^ expression here
```

...or when you confuse the inference engine by giving more than one type
to a variable:

```sh
bin/tie -e "x = 1; x = 'foo'"                                                                                   3.0.4p208
Could not determine type of `lasgn' expression on line 1 (TypeError)

Could be one of: [:int, :str]

  x = 1; x = 'foo'
         ^ expression here

Possibility 1 (line 1):

  x = 1; x = 'foo'
      ^ int

Possibility 2 (line 1):

  x = 1; x = 'foo'
             ^ str
```
