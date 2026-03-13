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
  end
end
