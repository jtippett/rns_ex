defmodule RNS.Vendor.ConfigObj.Section do
  @moduledoc """
  A section in a ConfigObj configuration, supporting nested sections,
  ordered key-value pairs, and type coercion methods.

  Sections track both scalar values (key=value pairs) and subsections
  separately, maintaining insertion order.
  """

  @type t :: %__MODULE__{
          depth: non_neg_integer(),
          path: [String.t()],
          data: %{String.t() => term()},
          scalars: [String.t()],
          sections: [String.t()],
          order: [String.t()],
          comments: [String.t()],
          inline_comment: String.t() | nil,
          scalar_comments: %{String.t() => {[String.t()], String.t() | nil}},
          initial_comment: [String.t()],
          final_comment: [String.t()],
          started: boolean()
        }

  defstruct depth: 0,
            path: [],
            data: %{},
            scalars: [],
            sections: [],
            order: [],
            comments: [],
            inline_comment: nil,
            scalar_comments: %{},
            initial_comment: [],
            final_comment: [],
            started: false

  @bools %{
    "yes" => true,
    "no" => false,
    "on" => true,
    "off" => false,
    "1" => true,
    "0" => false,
    "true" => true,
    "false" => false
  }

  @doc """
  Create a new empty section at the given depth.
  """
  @spec new(non_neg_integer()) :: t()
  def new(depth \\ 0) do
    %__MODULE__{depth: depth}
  end

  @doc """
  Get a value or subsection by key.
  """
  @spec get(t(), String.t()) :: term()
  def get(%__MODULE__{data: data}, key) do
    Map.get(data, key)
  end

  @doc """
  Get a value by key with a default.
  """
  @spec get(t(), String.t(), term()) :: term()
  def get(%__MODULE__{data: data}, key, default) do
    Map.get(data, key, default)
  end

  @doc """
  Check if a key exists.
  """
  @spec has_key?(t(), String.t()) :: boolean()
  def has_key?(%__MODULE__{data: data}, key) do
    Map.has_key?(data, key)
  end

  @doc """
  Put a scalar (key=value) into the section.
  """
  @spec put_scalar(t(), String.t(), term(), [String.t()], String.t() | nil) :: t()
  def put_scalar(section, key, value, comments \\ [], inline_comment \\ nil) do
    new_scalars =
      if key in section.scalars, do: section.scalars, else: section.scalars ++ [key]

    new_order =
      if key in section.order, do: section.order, else: section.order ++ [key]

    # Remove from sections if it was one (shouldn't happen, but be safe)
    new_sections = List.delete(section.sections, key)

    %{section |
      data: Map.put(section.data, key, value),
      scalars: new_scalars,
      sections: new_sections,
      order: new_order,
      scalar_comments: Map.put(section.scalar_comments, key, {comments, inline_comment})
    }
  end

  @doc """
  Put a subsection into the section.
  """
  @spec put_section(t(), String.t(), t()) :: t()
  def put_section(section, key, child) do
    new_sections =
      if key in section.sections, do: section.sections, else: section.sections ++ [key]

    new_order =
      if key in section.order, do: section.order, else: section.order ++ [key]

    # Remove from scalars if it was one
    new_scalars = List.delete(section.scalars, key)

    child = %{child | path: section.path ++ [key]}

    %{section |
      data: Map.put(section.data, key, child),
      sections: new_sections,
      scalars: new_scalars,
      order: new_order
    }
  end

  @doc """
  Get the list of scalar keys (in order).
  """
  @spec keys(t()) :: [String.t()]
  def keys(%__MODULE__{scalars: scalars}), do: scalars

  @doc """
  Get the list of section names (in order).
  """
  @spec section_names(t()) :: [String.t()]
  def section_names(%__MODULE__{sections: sections}), do: sections

  @doc """
  Iterate over scalar keys (like Python's `for option in section`).
  """
  @spec each_scalar(t(), (String.t(), term() -> any())) :: :ok
  def each_scalar(%__MODULE__{scalars: scalars, data: data}, fun) do
    Enum.each(scalars, fn key ->
      fun.(key, Map.get(data, key))
    end)
  end

  @doc """
  Convert the value for the given key to a boolean.

  Recognizes (case-insensitive): yes/no, on/off, 1/0, true/false.
  Raises `ArgumentError` if the value is not a recognized boolean string.
  """
  @spec as_bool(t(), String.t()) :: boolean()
  def as_bool(section, key) do
    val = get(section, key)

    cond do
      val == true -> true
      val == false -> false
      is_binary(val) ->
        case Map.get(@bools, String.downcase(val)) do
          nil -> raise ArgumentError, "Value #{inspect(val)} is neither True nor False"
          bool -> bool
        end

      true ->
        raise ArgumentError, "Value #{inspect(val)} is neither True nor False"
    end
  end

  @doc """
  Convert the value for the given key to an integer.
  """
  @spec as_int(t(), String.t()) :: integer()
  def as_int(section, key) do
    val = get(section, key)
    if is_integer(val), do: val, else: String.to_integer(val)
  end

  @doc """
  Convert the value for the given key to a float.
  """
  @spec as_float(t(), String.t()) :: float()
  def as_float(section, key) do
    val = get(section, key)

    cond do
      is_float(val) -> val
      is_integer(val) -> val / 1
      is_binary(val) ->
        case Float.parse(val) do
          {f, _} -> f
          :error -> raise ArgumentError, "invalid float: #{inspect(val)}"
        end
    end
  end

  @doc """
  Ensure the value for the given key is returned as a list.
  If it's already a list, return it. Otherwise wrap in a list.
  """
  @spec as_list(t(), String.t()) :: [term()]
  def as_list(section, key) do
    val = get(section, key)

    case val do
      list when is_list(list) -> list
      other -> [other]
    end
  end

  @doc """
  Convert a section to a plain map (recursively converts subsections).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = section) do
    Enum.reduce(section.order, %{}, fn key, acc ->
      val = Map.get(section.data, key)

      val =
        if is_struct(val, __MODULE__) do
          to_map(val)
        else
          val
        end

      Map.put(acc, key, val)
    end)
  end

  @doc """
  Fetch a value (for Access protocol compatibility).
  """
  @spec fetch(t(), String.t()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{data: data}, key) do
    Map.fetch(data, key)
  end

  defimpl Enumerable do
    def count(%RNS.Vendor.ConfigObj.Section{order: order}), do: {:ok, length(order)}

    def member?(%RNS.Vendor.ConfigObj.Section{data: data}, {key, val}) do
      {:ok, Map.get(data, key) == val}
    end

    def member?(%RNS.Vendor.ConfigObj.Section{data: data}, key) when is_binary(key) do
      {:ok, Map.has_key?(data, key)}
    end

    def member?(_, _), do: {:ok, false}

    def slice(%RNS.Vendor.ConfigObj.Section{order: order, data: data}) do
      size = length(order)

      {:ok, size,
       fn start, len, _step ->
         order
         |> Enum.slice(start, len)
         |> Enum.map(fn key -> {key, Map.get(data, key)} end)
       end}
    end

    def reduce(%RNS.Vendor.ConfigObj.Section{scalars: scalars, data: data}, acc, fun) do
      # Iterate over scalars only (matching Python's for key in section behavior)
      scalars
      |> Enum.map(fn key -> {key, Map.get(data, key)} end)
      |> Enumerable.List.reduce(acc, fun)
    end
  end
end
