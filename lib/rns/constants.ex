defmodule RNS.Constants do
  @moduledoc """
  Protocol constants for the Reticulum Network Stack.

  Constants are organized by domain and exposed via `use` macros that
  inject compile-time module attributes. This eliminates the need for
  runtime accessor functions and enables pattern matching on constants.

  ## Usage

      use RNS.Constants.Packet
      # Now @data, @announce, @context_none, etc. are available

      use RNS.Constants.Destination
      # Now @single, @group, @direction_in, etc. are available
  """

  defmodule Packet do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        @data 0x00
        @announce 0x01
        @linkrequest 0x02
        @proof 0x03

        @header_1 0x00
        @header_2 0x01

        @context_none 0x00
        @context_resource 0x01
        @context_resource_adv 0x02
        @context_resource_req 0x03
        @context_resource_hmu 0x04
        @context_resource_prf 0x05
        @context_resource_icl 0x06
        @context_resource_rcl 0x07
        @context_cache_request 0x08
        @context_request 0x09
        @context_response 0x0A
        @context_path_response 0x0B
        @context_command 0x0C
        @context_command_status 0x0D
        @context_channel 0x0E
        @context_keepalive 0xFA
        @context_linkidentify 0xFB
        @context_linkclose 0xFC
        @context_linkproof 0xFD
        @context_lrrtt 0xFE
        @context_lrproof 0xFF

        @flag_set 0x01
        @flag_unset 0x00

        @truncated_hashlength 128
        @dst_len div(@truncated_hashlength, 8)
        @mtu 500
        @header_maxsize 2 + 1 + @dst_len * 2
        @ifac_min_size 1
        @mdu @mtu - @header_maxsize - @ifac_min_size

        @token_overhead 48
        @identity_keysize 512
        @aes128_blocksize 16

        @encrypted_mdu div(@mdu - @token_overhead - div(@identity_keysize, 16), @aes128_blocksize) *
                          @aes128_blocksize - 1
        @plain_mdu @mdu

        @timeout_per_hop 6
      end
    end
  end

  defmodule Destination do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        @single 0x00
        @group 0x01
        @plain 0x02
        @link 0x03

        @prove_none 0x21
        @prove_app 0x22
        @prove_all 0x23

        @allow_none 0x00
        @allow_all 0x01
        @allow_list 0x02

        @in_direction 0x11
        @out_direction 0x12

        @pr_tag_window 30
        @ratchet_count 512
        @ratchet_interval 30 * 60

        @name_hash_length 80
        @truncated_hashlength 128
      end
    end
  end

  defmodule Link do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        @ecpubsize 32 + 32
        @keysize 32
        @link_mtu_size 3

        @status_pending 0x00
        @status_handshake 0x01
        @status_active 0x02
        @status_stale 0x03
        @status_closed 0x04

        @timeout 0x01
        @initiator_closed 0x02
        @destination_closed 0x03

        @accept_none 0x00
        @accept_app 0x01
        @accept_all 0x02

        @mode_aes128_cbc 0x00
        @mode_aes256_cbc 0x01
        @mode_aes256_gcm 0x02
        @mode_otp_reserved 0x03
        @mode_pq_reserved_1 0x04
        @mode_pq_reserved_2 0x05
        @mode_pq_reserved_3 0x06
        @mode_pq_reserved_4 0x07
        @enabled_modes [@mode_aes256_cbc]
        @mode_default @mode_aes256_cbc
        @mode_descriptions %{
          @mode_aes128_cbc => "AES_128_CBC",
          @mode_aes256_cbc => "AES_256_CBC",
          @mode_aes256_gcm => "MODE_AES256_GCM",
          @mode_otp_reserved => "MODE_OTP_RESERVED",
          @mode_pq_reserved_1 => "MODE_PQ_RESERVED_1",
          @mode_pq_reserved_2 => "MODE_PQ_RESERVED_2",
          @mode_pq_reserved_3 => "MODE_PQ_RESERVED_3",
          @mode_pq_reserved_4 => "MODE_PQ_RESERVED_4"
        }

        @mtu_bytemask 0x1FFFFF
        @mode_bytemask 0xE0

        @keepalive_max 360
        @keepalive_min 5
        @keepalive @keepalive_max
        @stale_factor 2
        @stale_time @stale_factor * @keepalive
        @keepalive_max_rtt 1.75
        @keepalive_timeout_factor 4
        @stale_grace 5
        @traffic_timeout_factor 6
        @traffic_timeout_min_ms 5
        @watchdog_max_sleep 5

        @mtu 500
        @ifac_min_size 1
        @header_minsize 2 + 1 + div(128, 8)
        @token_overhead 48
        @aes128_blocksize 16

        @link_mdu div(@mtu - @ifac_min_size - @header_minsize - @token_overhead, @aes128_blocksize) *
                    @aes128_blocksize - 1

        @response_max_grace_time 10
      end
    end
  end

  defmodule Channel do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        @smt_stream_data 0xFF00

        @window 2
        @window_min 2
        @window_min_limit_slow 2
        @window_min_limit_medium 5
        @window_min_limit_fast 16
        @window_max_slow 5
        @window_max_medium 12
        @window_max_fast 48
        @window_max @window_max_fast
        @window_flexibility 4
        @fast_rate_threshold 10
        @rtt_fast 0.18
        @rtt_medium 0.75
        @rtt_slow 1.45

        @seq_max 0xFFFF
        @seq_modulus @seq_max + 1

        @msgstate_new 0
        @msgstate_sent 1
        @msgstate_delivered 2
        @msgstate_failed 3

        @me_no_msg_type 0
        @me_invalid_msg_type 1
        @me_not_registered 2
        @me_link_not_ready 3
        @me_already_sent 4
        @me_too_big 5

        @max_tries 5
        @envelope_header_size 6
      end
    end
  end

  defmodule Identity do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        @curve "Curve25519"
        @keysize 512
        @ratchetsize 256
        @ratchet_expiry 60 * 60 * 24 * 30
        @hashlength 256
        @siglength @keysize
        @name_hash_length 80
        @truncated_hashlength 128
        @derived_key_length div(512, 8)
      end
    end
  end

  defmodule Interface do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        @mode_full 0x01
        @mode_point_to_point 0x02
        @mode_access_point 0x03
        @mode_roaming 0x04
        @mode_boundary 0x05
        @mode_gateway 0x06

        @discover_paths_for [@mode_access_point, @mode_gateway, @mode_roaming]

        @ia_freq_samples 6
        @oa_freq_samples 6

        @max_held_announces 256

        @ic_new_time 2 * 60 * 60
        @ic_burst_freq_new 3.5
        @ic_burst_freq 12
        @ic_burst_hold 1 * 60
        @ic_burst_penalty 5 * 60
        @ic_held_release_interval 30
      end
    end
  end

  defmodule PacketReceipt do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        @failed 0x00
        @sent 0x01
        @delivered 0x02
        @culled 0xFF

        @hashlength 256
        @siglength 512

        @expl_length div(@hashlength, 8) + div(@siglength, 8)
        @impl_length div(@siglength, 8)
      end
    end
  end
end
