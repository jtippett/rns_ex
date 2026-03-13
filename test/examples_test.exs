defmodule ExamplesTest do
  use ExUnit.Case, async: true

  @examples_dir Path.join(File.cwd!(), "examples")

  describe "example scripts" do
    test "minimal.exs parses without errors" do
      path = Path.join(@examples_dir, "minimal.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "echo.exs parses without errors" do
      path = Path.join(@examples_dir, "echo.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "announce.exs parses without errors" do
      path = Path.join(@examples_dir, "announce.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "broadcast.exs parses without errors" do
      path = Path.join(@examples_dir, "broadcast.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "link.exs parses without errors" do
      path = Path.join(@examples_dir, "link.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "request.exs parses without errors" do
      path = Path.join(@examples_dir, "request.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "identify.exs parses without errors" do
      path = Path.join(@examples_dir, "identify.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "channel.exs parses without errors" do
      path = Path.join(@examples_dir, "channel.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "buffer.exs parses without errors" do
      path = Path.join(@examples_dir, "buffer.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "resource.exs parses without errors" do
      path = Path.join(@examples_dir, "resource.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "filetransfer.exs parses without errors" do
      path = Path.join(@examples_dir, "filetransfer.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "speedtest.exs parses without errors" do
      path = Path.join(@examples_dir, "speedtest.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end

    test "ratchets.exs parses without errors" do
      path = Path.join(@examples_dir, "ratchets.exs")
      source = File.read!(path)
      assert {:ok, _ast} = Code.string_to_quoted(source, file: path)
    end
  end
end
