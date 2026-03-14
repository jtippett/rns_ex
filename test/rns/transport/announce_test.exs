defmodule RNS.Transport.AnnounceTest do
  use ExUnit.Case, async: true

  alias RNS.Transport.Announce

  describe "struct" do
    test "creates with all fields" do
      announce = %Announce{
        dest_hash: <<1, 2, 3>>,
        identity: %{name: "test"},
        app_data: <<4, 5, 6>>,
        name_hash: <<7, 8, 9>>
      }

      assert announce.dest_hash == <<1, 2, 3>>
      assert announce.identity == %{name: "test"}
      assert announce.app_data == <<4, 5, 6>>
      assert announce.name_hash == <<7, 8, 9>>
    end

    test "defaults to nil" do
      announce = %Announce{}

      assert announce.dest_hash == nil
      assert announce.identity == nil
      assert announce.app_data == nil
      assert announce.name_hash == nil
    end
  end
end
