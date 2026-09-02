# frozen_string_literal: true

module Coldwire
  # Read from the VERSION file at the root, which is the single place the number is written:
  # the gemspec takes it from here rather than from a second copy, and a release only has to
  # touch one line.
  #
  # `.freeze` because the frozen_string_literal pragma above covers literals in this file, not
  # a string that arrives from IO.
  VERSION = File.read(File.expand_path("../../VERSION", __dir__)).strip.freeze
end
