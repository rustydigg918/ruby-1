require 'test/unit'

require 'tempfile'
require_relative 'envutil'
require 'tmpdir'

class TestRequire < Test::Unit::TestCase
  def test_require_invalid_shared_object
    t = Tempfile.new(["test_ruby_test_require", ".so"])
    t.puts "dummy"
    t.close

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      begin
        require \"#{ t.path }\"
      rescue LoadError
        p :ok
      end
    INPUT
  end

  def test_require_too_long_filename
    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      begin
        require '#{ "foo/" * 10000 }foo'
      rescue LoadError
        p :ok
      end
    INPUT

    begin
      assert_in_out_err(["-S", "foo/" * 10000 + "foo"], "") do |r, e|
        assert_equal([], r)
        assert_operator(2, :<=, e.size)
        assert_equal("openpath: pathname too long (ignored)", e.first)
        assert_match(/\(LoadError\)/, e.last)
      end
    rescue Errno::EINVAL
      # too long commandline may be blocked by OS.
    end
  end

  def test_require_path_home
    env_rubypath, env_home = ENV["RUBYPATH"], ENV["HOME"]

    ENV["RUBYPATH"] = "~"
    ENV["HOME"] = "/foo" * 10000
    assert_in_out_err(%w(-S test_ruby_test_require), "", [], /^.+$/)

    ENV["RUBYPATH"] = "~" + "/foo" * 10000
    ENV["HOME"] = "/foo"
    assert_in_out_err(%w(-S test_ruby_test_require), "", [], /^.+$/)

    t = Tempfile.new(["test_ruby_test_require", ".rb"])
    t.puts "p :ok"
    t.close
    ENV["RUBYPATH"] = "~"
    ENV["HOME"], name = File.split(t.path)
    assert_in_out_err(["-S", name], "", %w(:ok), [])

  ensure
    env_rubypath ? ENV["RUBYPATH"] = env_rubypath : ENV.delete("RUBYPATH")
    env_home ? ENV["HOME"] = env_home : ENV.delete("HOME")
  end

  def test_define_class
    begin
      require "socket"
    rescue LoadError
      return
    end

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      BasicSocket = 1
      begin
        require 'socket'
        p :ng
      rescue TypeError
        p :ok
      end
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      class BasicSocket; end
      begin
        require 'socket'
        p :ng
      rescue TypeError
        p :ok
      end
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      class BasicSocket < IO; end
      begin
        require 'socket'
        p :ok
      rescue Exception
        p :ng
      end
    INPUT
  end

  def test_define_class_under
    begin
      require "zlib"
    rescue LoadError
      return
    end

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      module Zlib; end
      Zlib::Error = 1
      begin
        require 'zlib'
        p :ng
      rescue TypeError
        p :ok
      end
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      module Zlib; end
      class Zlib::Error; end
      begin
        require 'zlib'
        p :ng
      rescue NameError
        p :ok
      end
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      module Zlib; end
      class Zlib::Error < StandardError; end
      begin
        require 'zlib'
        p :ok
      rescue Exception
        p :ng
      end
    INPUT
  end

  def test_define_module
    begin
      require "zlib"
    rescue LoadError
      return
    end

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      Zlib = 1
      begin
        require 'zlib'
        p :ng
      rescue TypeError
        p :ok
      end
    INPUT
  end

  def test_define_module_under
    begin
      require "socket"
    rescue LoadError
      return
    end

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      class BasicSocket < IO; end
      class Socket < BasicSocket; end
      Socket::Constants = 1
      begin
        require 'socket'
        p :ng
      rescue TypeError
        p :ok
      end
    INPUT
  end

  def test_load
    t = Tempfile.new(["test_ruby_test_require", ".rb"])
    t.puts "module Foo; end"
    t.puts "at_exit { p :wrap_end }"
    t.puts "at_exit { raise 'error in at_exit test' }"
    t.puts "p :ok"
    t.close

    assert_in_out_err([], <<-INPUT, %w(:ok :end :wrap_end), /error in at_exit test/)
      load(#{ t.path.dump }, true)
      GC.start
      p :end
    INPUT

    assert_raise(ArgumentError) { at_exit }
  end

  def test_load2  # [ruby-core:25039]
    t = Tempfile.new(["test_ruby_test_require", ".rb"])
    t.puts "Hello = 'hello'"
    t.puts "class Foo"
    t.puts "  p Hello"
    t.puts "end"
    t.close

    assert_in_out_err([], <<-INPUT, %w("hello"), [])
      load(#{ t.path.dump }, true)
    INPUT
  end

  def test_tainted_loadpath
    t = Tempfile.new(["test_ruby_test_require", ".rb"])
    abs_dir, file = File.split(t.path)
    abs_dir = File.expand_path(abs_dir).untaint

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      abs_dir = "#{ abs_dir }"
      $: << abs_dir
      require "#{ file }"
      p :ok
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      abs_dir = "#{ abs_dir }"
      $: << abs_dir.taint
      require "#{ file }"
      p :ok
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      abs_dir = "#{ abs_dir }"
      $: << abs_dir.taint
      $SAFE = 1
      begin
        require "#{ file }"
      rescue SecurityError
        p :ok
      end
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      abs_dir = "#{ abs_dir }"
      $: << abs_dir.taint
      $SAFE = 1
      begin
        require "#{ file }"
      rescue SecurityError
        p :ok
      end
    INPUT

    assert_in_out_err([], <<-INPUT, %w(:ok), [])
      abs_dir = "#{ abs_dir }"
      $: << abs_dir << 'elsewhere'.taint
      require "#{ file }"
      p :ok
    INPUT
  end

  def test_relative
    load_path = $:.dup
    $:.delete(".")
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) do
        Dir.mkdir('x')
        File.open('x/t.rb', 'wb') {}
        File.open('x/a.rb', 'wb') {|f| f.puts("require_relative('t.rb')")}
        assert require('./x/t.rb')
        assert !require(File.expand_path('x/t.rb'))
        assert_nothing_raised(LoadError) {require('./x/a.rb')}
        assert_raise(LoadError) {require('x/t.rb')}
        File.unlink(*Dir.glob('x/*'))
        Dir.rmdir("#{tmp}/x")
        $:.replace(load_path)
        load_path = nil
        assert(!require('tmpdir'))
      end
    end
  ensure
    $:.replace(load_path) if load_path
  end

  def test_relative_symlink
    Dir.mktmpdir {|tmp|
      Dir.chdir(tmp) {
        Dir.mkdir "a"
        Dir.mkdir "b"
        File.open("a/lib.rb", "w") {|f| f.puts 'puts "a/lib.rb"' }
        File.open("b/lib.rb", "w") {|f| f.puts 'puts "b/lib.rb"' }
        File.open("a/tst.rb", "w") {|f| f.puts 'require_relative "lib"' }
        File.symlink("../a/tst.rb", "b/tst.rb")
        result = IO.popen([EnvUtil.rubybin, "b/tst.rb"]).read
        assert_equal("a/lib.rb\n", result, "[ruby-dev:40040]")
      }
    }
  end
end
