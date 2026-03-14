defmodule RNS.JasonEncoderTest do
  use ExUnit.Case, async: true

  test "jason is available as a dependency" do
    assert Code.ensure_loaded?(Jason)
  end
end
