defmodule RNS.Vendor.ConfigObj do
  @moduledoc """
  INI-style configuration file parser compatible with Python's ConfigObj.

  Supports nested sections via bracket depth (`[section]`, `[[subsection]]`),
  key=value pairs, comments (`#`), quoted values, list values (comma-separated),
  multi-line values (triple quotes), and type coercion (booleans, integers,
  floats, lists).

  This is used by `RNS.Reticulum` to parse RNS configuration files.
  """

  alias RNS.Vendor.ConfigObj.Section

  @doc """
  Parse a config string or list of lines into a ConfigObj Section.

  ## Examples

      iex> {:ok, config} = RNS.Vendor.ConfigObj.parse("[reticulum]\\nenable_transport = no\\n")
      iex> RNS.Vendor.ConfigObj.Section.get(config, "reticulum") |> RNS.Vendor.ConfigObj.Section.get("enable_transport")
      "no"
  """
  @spec parse(String.t() | [String.t()]) :: {:ok, Section.t()} | {:error, term()}
  def parse(input) when is_binary(input) do
    lines = String.split(input, ~r/\r\n|\r|\n/, trim: false)
    # Remove trailing empty string from split if input ends with newline
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    do_parse(lines)
  end

  def parse(lines) when is_list(lines) do
    lines =
      Enum.map(lines, fn line ->
        line
        |> to_string()
        |> String.trim_trailing("\r\n")
        |> String.trim_trailing("\r")
        |> String.trim_trailing("\n")
      end)

    do_parse(lines)
  end

  @doc """
  Parse a config file. Returns `{:ok, section}` or `{:error, reason}`.
  """
  @spec parse_file(String.t()) :: {:ok, Section.t()} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, content} ->
        # Handle BOM
        content = strip_bom(content)
        parse(content)

      {:error, reason} ->
        {:error, {:file_error, reason, path}}
    end
  end

  @doc """
  Serialize a ConfigObj Section back to a string.
  """
  @spec write(Section.t()) :: String.t()
  def write(section) do
    lines = write_section(section, 0) ++ write_final_comment(section)
    initial = write_initial_comment(section)

    (initial ++ lines)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # --- Private parsing ---

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest

  defp strip_bom(<<0xFF, 0xFE, rest::binary>>),
    do: :unicode.characters_to_binary(rest, :utf16_little)

  defp strip_bom(<<0xFE, 0xFF, rest::binary>>),
    do: :unicode.characters_to_binary(rest, :utf16_big)

  defp strip_bom(other), do: other

  defp do_parse(lines) do
    root = Section.new(0)

    {root, _comment_list, _cur_section, errors} =
      parse_lines(lines, 0, root, root, [], [])

    case errors do
      [] -> {:ok, root}
      [error | _] -> {:error, error}
    end
  end

  defp parse_lines([], _index, root, _cur_section, comment_list, errors) do
    # Preserve final comment
    root =
      if comment_list != [] do
        %{root | final_comment: comment_list}
      else
        root
      end

    {root, comment_list, root, errors}
  end

  defp parse_lines([line | rest], index, root, cur_section, comment_list, errors) do
    sline = String.trim(line)

    cond do
      # Empty line or comment
      sline == "" or String.starts_with?(sline, "#") ->
        # Check if we haven't started real content yet (initial comment)
        if not root.started do
          root = %{root | initial_comment: root.initial_comment ++ [line]}
          parse_lines(rest, index + 1, root, cur_section, [], errors)
        else
          parse_lines(rest, index + 1, root, cur_section, comment_list ++ [line], errors)
        end

      # Section marker
      match = parse_section_marker(line) ->
        {sect_name, depth, inline_comment} = match
        root = if not root.started, do: %{root | started: true}, else: root
        # Update cur_section if it was root (to pick up started/initial_comment changes)
        cur_section = if cur_section.path == [], do: root, else: cur_section

        case resolve_parent(cur_section, root, depth) do
          {:ok, parent} ->
            # If parent is at root level, use root to preserve metadata
            parent = if parent.path == [], do: root, else: parent
            new_section = Section.new(depth)
            new_section = %{new_section | comments: comment_list, inline_comment: inline_comment}
            parent = Section.put_section(parent, sect_name, new_section)

            # Update the root by walking back
            root = update_in_tree(root, parent, sect_name)
            # Get reference to the newly created section
            new_cur = get_section_at_path(root, section_path(parent, sect_name))

            parse_lines(rest, index + 1, root, new_cur, [], errors)

          {:error, reason} ->
            parse_lines(
              rest,
              index + 1,
              root,
              cur_section,
              [],
              errors ++ [{reason, index + 1, line}]
            )
        end

      # Key = value
      match = parse_key_value(line) ->
        root = if not root.started, do: %{root | started: true}, else: root
        cur_section = if cur_section.path == [], do: root, else: cur_section
        {key, raw_value, _indent} = match

        # Check for multi-line values (triple quotes)
        {value, inline_comment, rest, index} =
          case parse_multiline_start(raw_value) do
            {:single_line, val, comment} ->
              {val, comment, rest, index}

            {:multiline, quot, partial} ->
              collect_multiline(partial, quot, rest, index)

            nil ->
              {val, comment} = handle_value(raw_value)
              {val, comment, rest, index}
          end

        key = unquote_value(key)

        cur_section =
          cur_section
          |> Section.put_scalar(key, value, comment_list, inline_comment)

        root = replace_section_in_tree(root, cur_section)

        parse_lines(rest, index + 1, root, cur_section, [], errors)

      # Invalid line
      true ->
        parse_lines(
          rest,
          index + 1,
          root,
          cur_section,
          [],
          errors ++ [{:parse_error, index + 1, line}]
        )
    end
  end

  # Parse a section marker like [section] or [[subsection]]
  # Returns {name, depth, inline_comment} or nil
  defp parse_section_marker(line) do
    # Match: optional whitespace, one or more [, section name, one or more ], optional comment
    regex = ~r/^(\s*)((?:\[\s*)+)((?:".*?")|(?:'.*?')|(?:[^'"\s].*?))((?:\s*\])+)\s*(\#.*)?$/

    case Regex.run(regex, line) do
      [_, _indent, open, name, close, comment] ->
        open_depth = count_brackets(open, ?[)
        close_depth = count_brackets(close, ?])

        if open_depth == close_depth do
          {unquote_value(String.trim(name)), open_depth, clean_comment(comment)}
        else
          nil
        end

      [_, _indent, open, name, close] ->
        open_depth = count_brackets(open, ?[)
        close_depth = count_brackets(close, ?])

        if open_depth == close_depth do
          {unquote_value(String.trim(name)), open_depth, nil}
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp count_brackets(str, char) do
    str |> String.to_charlist() |> Enum.count(&(&1 == char))
  end

  defp clean_comment(nil), do: nil
  defp clean_comment(""), do: nil
  defp clean_comment(comment), do: String.trim(comment)

  # Parse key = value line
  # Returns {key, raw_value, indent} or nil
  defp parse_key_value(line) do
    regex = ~r/^(\s*)((?:".*?")|(?:'.*?')|(?:[^'"=].*?))\s*=\s*(.*)$/

    case Regex.run(regex, line) do
      [_, indent, key, value] ->
        {String.trim(key), value, indent}

      _ ->
        nil
    end
  end

  # Handle value: unquote, remove comment, handle lists
  defp handle_value(raw) do
    raw = String.trim(raw)

    cond do
      # Empty value
      raw == "" ->
        {"", nil}

      # Single comma = empty list
      raw == "," ->
        {[], nil}

      true ->
        parse_value_with_comment(raw)
    end
  end

  defp parse_value_with_comment(raw) do
    # Try to extract value and inline comment
    # Need to handle quoted strings, lists with commas, and # comments
    {value_part, comment} = split_value_comment(raw)
    value_part = String.trim(value_part)

    cond do
      # Check if it's a list (contains unquoted commas)
      is_list_value?(value_part) ->
        items = parse_list_value(value_part)
        {items, comment}

      true ->
        {unquote_value(value_part), comment}
    end
  end

  # Split a raw value string into the value part and optional inline comment
  defp split_value_comment(raw) do
    # Walk through the string tracking quote state
    split_at = find_comment_position(raw, 0, nil)

    case split_at do
      nil ->
        {String.trim(raw), nil}

      pos ->
        value = String.slice(raw, 0, pos) |> String.trim()
        comment = String.slice(raw, pos, String.length(raw) - pos) |> String.trim()
        {value, comment}
    end
  end

  defp find_comment_position(<<>>, _pos, _quote), do: nil

  defp find_comment_position(<<c, rest::binary>>, pos, nil) when c in [?", ?'] do
    find_comment_position(rest, pos + 1, c)
  end

  defp find_comment_position(<<c, rest::binary>>, pos, c) do
    # Closing quote
    find_comment_position(rest, pos + 1, nil)
  end

  defp find_comment_position(<<?#, _rest::binary>>, pos, nil) do
    pos
  end

  defp find_comment_position(<<_c, rest::binary>>, pos, quote_char) do
    find_comment_position(rest, pos + 1, quote_char)
  end

  # Check if value contains unquoted commas (making it a list)
  defp is_list_value?(value) do
    has_unquoted_comma?(value, nil)
  end

  defp has_unquoted_comma?(<<>>, _quote), do: false

  defp has_unquoted_comma?(<<c, rest::binary>>, nil) when c in [?", ?'] do
    has_unquoted_comma?(rest, c)
  end

  defp has_unquoted_comma?(<<c, rest::binary>>, c) do
    has_unquoted_comma?(rest, nil)
  end

  defp has_unquoted_comma?(<<?,, _rest::binary>>, nil), do: true

  defp has_unquoted_comma?(<<_c, rest::binary>>, quote_char) do
    has_unquoted_comma?(rest, quote_char)
  end

  # Parse a comma-separated list value
  defp parse_list_value(value) do
    split_list(value, nil, <<>>, [])
    |> Enum.map(&String.trim/1)
    |> Enum.map(&unquote_value/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_list(<<>>, _quote, current, acc) do
    Enum.reverse([current | acc])
  end

  defp split_list(<<c, rest::binary>>, nil, current, acc) when c in [?", ?'] do
    split_list(rest, c, <<current::binary, c>>, acc)
  end

  defp split_list(<<c, rest::binary>>, c, current, acc) do
    split_list(rest, nil, <<current::binary, c>>, acc)
  end

  defp split_list(<<?,, rest::binary>>, nil, current, acc) do
    split_list(rest, nil, <<>>, [current | acc])
  end

  defp split_list(<<c, rest::binary>>, quote_char, current, acc) do
    split_list(rest, quote_char, <<current::binary, c>>, acc)
  end

  defp unquote_value(value) when is_list(value), do: value

  defp unquote_value(value) do
    trimmed = String.trim(value)

    cond do
      String.length(trimmed) >= 2 and
        String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") ->
        String.slice(trimmed, 1..-2//1)

      String.length(trimmed) >= 2 and
        String.starts_with?(trimmed, "'") and String.ends_with?(trimmed, "'") ->
        String.slice(trimmed, 1..-2//1)

      true ->
        trimmed
    end
  end

  # Multi-line value detection
  defp parse_multiline_start(raw) do
    trimmed = String.trim(raw)

    Enum.find_value(["\"\"\"", "'''"], fn quot ->
      if String.starts_with?(trimmed, quot) do
        after_open = String.slice(trimmed, 3, String.length(trimmed) - 3)

        if String.contains?(after_open, quot) do
          # Single-line triple-quoted value
          [val | rest_parts] = String.split(after_open, quot, parts: 2)

          comment =
            case rest_parts do
              [c] -> clean_comment(String.trim(c))
              _ -> nil
            end

          {:single_line, val, comment}
        else
          {:multiline, quot, after_open}
        end
      end
    end)
  end

  defp collect_multiline(partial, quot, lines, index) do
    collect_multiline_lines(quot, lines, index, [partial])
  end

  defp collect_multiline_lines(_quot, [], index, acc) do
    # Unterminated multi-line - return what we have
    value = acc |> Enum.reverse() |> Enum.join("\n")
    {value, nil, [], index}
  end

  defp collect_multiline_lines(quot, [line | rest], index, acc) do
    if String.contains?(line, quot) do
      # Found closing triple quote
      [before_close | after_parts] = String.split(line, quot, parts: 2)
      all_lines = Enum.reverse([before_close | acc])
      value = Enum.join(all_lines, "\n")

      comment =
        case after_parts do
          [c] -> clean_comment(String.trim(c))
          _ -> nil
        end

      {value, comment, rest, index + 1}
    else
      collect_multiline_lines(quot, rest, index + 1, [line | acc])
    end
  end

  # --- Tree navigation helpers ---

  # Build a path list to a section from the root
  defp section_path(%Section{path: path}, name), do: path ++ [name]

  # Resolve which parent a new section at given depth should be added to
  defp resolve_parent(cur_section, root, depth) do
    cond do
      depth == cur_section.depth + 1 ->
        # Child of current section
        {:ok, cur_section}

      depth == cur_section.depth ->
        # Sibling - parent is cur_section's parent
        {:ok, get_parent(root, cur_section)}

      depth < cur_section.depth ->
        # Dropping back to a previous level
        parent = walk_back(root, cur_section, depth)
        {:ok, parent}

      depth > cur_section.depth + 1 ->
        {:error, :section_too_nested}
    end
  end

  defp get_parent(root, section) do
    case section.path do
      [] -> root
      path -> get_section_at_path(root, Enum.drop(path, -1))
    end
  end

  defp walk_back(root, section, target_depth) do
    parent = get_parent(root, section)

    if parent.depth >= target_depth do
      walk_back(root, parent, target_depth)
    else
      parent
    end
  end

  defp get_section_at_path(root, []), do: root

  defp get_section_at_path(root, [name | rest]) do
    case Section.get(root, name) do
      %Section{} = section -> get_section_at_path(section, rest)
      _ -> root
    end
  end

  # Propagate a modified parent back into the root tree
  defp update_in_tree(root, parent, _sect_name) do
    case parent.path do
      [] ->
        # Parent is root - return the updated parent directly
        parent

      path ->
        # Parent is deeper - rebuild path from root to parent
        rebuild_tree(root, path, parent)
    end
  end

  defp replace_section_in_tree(root, section) do
    case section.path do
      [] -> section
      path -> rebuild_tree(root, path, section)
    end
  end

  defp rebuild_tree(_root, [], replacement) do
    # Merge root-level data
    %{replacement | path: []}
  end

  defp rebuild_tree(root, path, replacement) do
    do_rebuild(root, path, replacement)
  end

  defp do_rebuild(root, [name], replacement) do
    Section.put_section(root, name, replacement)
  end

  defp do_rebuild(root, [name | rest], replacement) do
    child = Section.get(root, name)

    if is_struct(child, Section) do
      updated_child = do_rebuild(child, rest, replacement)
      Section.put_section(root, name, updated_child)
    else
      root
    end
  end

  # --- Writing ---

  defp write_initial_comment(%Section{initial_comment: []}), do: []
  defp write_initial_comment(%Section{initial_comment: comments}), do: comments

  defp write_final_comment(%Section{final_comment: []}), do: []
  defp write_final_comment(%Section{final_comment: comments}), do: comments

  defp write_section(section, depth) do
    indent = String.duplicate("  ", depth)

    entries =
      Enum.flat_map(section.order, fn key ->
        cond do
          key in section.sections ->
            child = Section.get(section, key)
            comments = write_entry_comments(child.comments, indent)
            marker = write_section_marker(indent, depth + 1, key, child.inline_comment)
            body = write_section(child, depth + 1)
            comments ++ [marker] ++ body

          key in section.scalars ->
            value = Section.get(section, key)
            {entry_comments, inline_comment} = Map.get(section.scalar_comments, key, {[], nil})
            comments = write_entry_comments(entry_comments, indent)
            line = write_key_value(indent, key, value, inline_comment)
            comments ++ [line]

          true ->
            []
        end
      end)

    entries
  end

  defp write_entry_comments([], _indent), do: []

  defp write_entry_comments(comments, _indent) do
    comments
  end

  defp write_section_marker(indent, depth, name, nil) do
    brackets_open = String.duplicate("[", depth)
    brackets_close = String.duplicate("]", depth)
    "#{indent}#{brackets_open}#{quote_key(name)}#{brackets_close}"
  end

  defp write_section_marker(indent, depth, name, comment) do
    brackets_open = String.duplicate("[", depth)
    brackets_close = String.duplicate("]", depth)
    "#{indent}#{brackets_open}#{quote_key(name)}#{brackets_close} #{comment}"
  end

  defp write_key_value(indent, key, value, inline_comment) do
    quoted_val = quote_value(value)
    line = "#{indent}#{quote_key(key)} = #{quoted_val}"

    case inline_comment do
      nil -> line
      comment -> "#{line} #{comment}"
    end
  end

  defp quote_key(key) do
    if String.contains?(key, " ") or String.contains?(key, "=") do
      "\"#{key}\""
    else
      key
    end
  end

  defp quote_value(value) when is_list(value) do
    case value do
      [] -> ","
      items -> Enum.map_join(items, ", ", &quote_single_value/1)
    end
  end

  defp quote_value(value), do: quote_single_value(value)

  defp quote_single_value(value) when is_binary(value) do
    cond do
      String.contains?(value, "\n") ->
        if String.contains?(value, ~s(""")) do
          "'''#{value}'''"
        else
          ~s("""#{value}""")
        end

      value == "" ->
        ~s("")

      needs_quoting?(value) ->
        if String.contains?(value, "\"") do
          "'#{value}'"
        else
          ~s("#{value}")
        end

      true ->
        value
    end
  end

  defp quote_single_value(value), do: Kernel.to_string(value)

  defp needs_quoting?(value) do
    first = String.first(value)
    last = String.last(value)

    first in [" ", "\t", "'", "\""] or
      last in [" ", "\t", "'", "\""] or
      String.contains?(value, ",") or
      String.contains?(value, "#")
  end
end
