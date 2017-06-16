defmodule Antidote.ParseError do
  @type t :: %__MODULE__{position: integer, data: String.t}

  defexception [:position, :token, :data]

  def message(%{position: position, token: token}) when is_binary(token) do
    "unexpected sequence at position #{position}: #{inspect token}"
  end
  def message(%{position: position, data: data}) when position == byte_size(data) do
    "unexpected end of input at position #{position}"
  end
  def message(%{position: position, data: data}) do
    byte = :binary.at(data, position)
    str = <<byte>>
    if String.printable?(str) do
      "unexpected byte at position #{position}: " <>
        "#{inspect byte, base: :hex} ('#{str}')"
    else
      "unexpected byte at position #{position}: " <>
        "#{inspect byte, base: :hex}"
    end
  end
end

defmodule Antidote.Parser do
  import Bitwise

  alias Antidote.{ParseError, Codegen}

  # @compile :native

  # We use integers instead of atoms to take advantage of the jump table
  # optimization
  @terminate 0
  @array     1
  @key       2
  @object    3

  def parse(data) when is_binary(data) do
    try do
      value(data, data, 0, [@terminate])
    catch
      {:position, position} ->
        {:error, %ParseError{position: position, data: data}}
      {:token, token, position} ->
        {:error, %ParseError{token: token, position: position, data: data}}
    else
      value ->
        {:ok, value}
    end
  end

  ranges = [{?0..?9, :skip}, {?-, :skip}, {?\", :skip}, {'\s\n\t\r', :value},
            {hd('{'), :object}, {hd('['), :array}, {hd(']'), :empty_array},
            {?n, :null}, {?t, :value_true}, {?f, :value_false}]

  for {byte, action} <- Codegen.jump_table(ranges, :error), action != :skip do
    defp value(<<unquote(byte), rest::bits>>, original, skip, stack) do
      unquote(action)(rest, original, skip + 1, stack)
    end
  end
  for byte <- ?1..?9 do
    defp value(<<unquote(byte), rest::bits>>, original, skip, stack) do
      number(rest, original, skip, stack, 1)
    end
  end
  defp value(<<?-, rest::bits>>, original, skip, stack) do
    number_minus(rest, original, skip, stack)
  end
  defp value(<<?\", rest::bits>>, original, skip, stack) do
    string(rest, original, skip + 1, stack, 0)
  end
  defp value(<<?0, rest::bits>>, original, skip, stack) do
    number_zero(rest, original, skip, stack, 1)
  end
  defp value(<<_rest::bits>>, original, skip, _stack) do
    error(original, skip)
  end

  digits = '0123456789'

  defp number_minus(<<?0, rest::bits>>, original, skip, stack) do
    number_zero(rest, original, skip, stack, 2)
  end
  defp number_minus(<<byte, rest::bits>>, original, skip, stack)
       when byte in '123456789' do
    number(rest, original, skip, stack, 2)
  end
  defp number_minus(<<_rest::bits>>, original, skip, _stack) do
    error(original, skip + 1)
  end

  defp number(<<byte, rest::bits>>, original, skip, stack, len)
       when byte in unquote(digits) do
    number(rest, original, skip, stack, len + 1)
  end
  defp number(<<?., rest::bits>>, original, skip, stack, len) do
    number_frac(rest, original, skip, stack, len + 1)
  end
  defp number(<<e, rest::bits>>, original, skip, stack, len) when e in 'eE' do
    prefix = binary_part(original, skip, len)
    number_exp_copy(rest, original, skip + len + 1, stack, prefix)
  end
  defp number(<<rest::bits>>, original, skip, stack, len) do
    int = String.to_integer(binary_part(original, skip, len))
    continue(rest, original, skip + len, stack, int)
  end

  defp number_frac(<<byte, rest::bits>>, original, skip, stack, len)
       when byte in unquote(digits) do
    number_frac_cont(rest, original, skip, stack, len + 1)
  end
  defp number_frac(<<_rest::bits>>, original, skip, _stack, len) do
    error(original, skip + len)
  end

  defp number_frac_cont(<<byte, rest::bits>>, original, skip, stack, len)
       when byte in unquote(digits) do
    number_frac_cont(rest, original, skip, stack, len + 1)
  end
  defp number_frac_cont(<<e, rest::bits>>, original, skip, stack, len)
       when e in 'eE' do
    number_exp(rest, original, skip, stack, len + 1)
  end
  defp number_frac_cont(<<rest::bits>>, original, skip, stack, len) do
    token = binary_part(original, skip, len)
    float = try_parse_float(token, token, skip)
    continue(rest, original, skip + len, stack, float)
  end

  defp number_exp(<<byte, rest::bits>>, original, skip, stack, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, len + 1)
  end
  defp number_exp(<<byte, rest::bits>>, original, skip, stack, len)
       when byte in '+-' do
    number_exp_sign(rest, original, skip, stack, len + 1)
  end
  defp number_exp(<<_rest::bits>>, original, skip, _stack, len) do
    error(original, skip + len)
  end

  defp number_exp_sign(<<byte, rest::bits>>, original, skip, stack, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, len + 1)
  end
  defp number_exp_sign(<<_rest::bits>>, original, skip, _stack, len) do
    error(original, skip + len)
  end

  defp number_exp_cont(<<byte, rest::bits>>, original, skip, stack, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, len + 1)
  end
  defp number_exp_cont(<<rest::bits>>, original, skip, stack, len) do
    token = binary_part(original, skip, len)
    float = try_parse_float(token, token, skip)
    continue(rest, original, skip + len, stack, float)
  end

  defp number_exp_copy(<<byte, rest::bits>>, original, skip, stack, prefix)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, prefix, 1)
  end
  defp number_exp_copy(<<byte, rest::bits>>, original, skip, stack, prefix)
       when byte in '+-' do
    number_exp_sign(rest, original, skip, stack, prefix, 1)
  end
  defp number_exp_copy(<<_rest::bits>>, original, skip, _stack, _prefix) do
    error(original, skip)
  end

  defp number_exp_sign(<<byte, rest::bits>>, original, skip, stack, prefix, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, prefix, len + 1)
  end
  defp number_exp_sign(<<_rest::bits>>, original, skip, _stack, _prefix, len) do
    error(original, skip + len)
  end

  defp number_exp_cont(<<byte, rest::bits>>, original, skip, stack, prefix, len)
       when byte in unquote(digits) do
    number_exp_cont(rest, original, skip, stack, prefix, len + 1)
  end
  defp number_exp_cont(<<rest::bits>>, original, skip, stack, prefix, len) do
    suffix = binary_part(original, skip, len)
    string = prefix <> ".0e" <> suffix
    prefix_size = byte_size(prefix)
    initial_skip = skip - prefix_size - 1
    final_skip = skip + len
    token = binary_part(original, initial_skip, prefix_size + len + 1)
    float = try_parse_float(string, token, initial_skip)
    continue(rest, original, final_skip, stack, float)
  end

  defp number_zero(<<?., rest::bits>>, original, skip, stack, len) do
    number_frac(rest, original, skip, stack, len + 1)
  end
  defp number_zero(<<e, rest::bits>>, original, skip, stack, len) when e in 'eE' do
    number_exp_copy(rest, original, skip + len + 1, stack, "0")
  end
  defp number_zero(<<rest::bits>>, original, skip, stack, len) do
    continue(rest, original, skip + len, stack, 0)
  end

  @compile {:inline, array: 4, empty_array: 4}

  defp array(rest, original, skip, stack) do
    value(rest, original, skip, [@array, [] | stack])
  end

  defp empty_array(rest, original, skip, stack) do
    case stack do
      [@array, [] | stack] ->
        continue(rest, original, skip, stack, [])
      _ ->
        error(original, skip - 1)
    end
  end

  ranges = [{'\s\n\t\r', :array}, {hd(']'), :continue}, {?,, :value}]
  array_jt = Codegen.jump_table(ranges, :error)

  Enum.map(array_jt, fn
    {byte, :array} ->
      defp array(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        array(rest, original, skip + 1, stack, value)
      end
    {byte, :continue} ->
      defp array(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        [acc | stack] = stack
        continue(rest, original, skip + 1, stack, :lists.reverse([value | acc]))
      end
    {byte, :value} ->
      defp array(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        [acc | stack] = stack
        value(rest, original, skip + 1, [@array, [value | acc] | stack])
      end
    {byte, :error} ->
      defp array(<<unquote(byte), _rest::bits>>, original, skip, _stack, _value) do
        error(original, skip)
      end
  end)
  defp array(<<_rest::bits>>, original, skip, _stack, _value) do
    error(original, skip)
  end

  @compile {:inline, object: 4}

  defp object(rest, original, skip, stack) do
    key(rest, original, skip, [[] | stack])
  end

  ranges = [{'\s\n\t\r', :object}, {hd('}'), :continue}, {?,, :key}]
  object_jt = Codegen.jump_table(ranges, :error)

  Enum.map(object_jt, fn
    {byte, :object} ->
      defp object(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        object(rest, original, skip + 1, stack, value)
      end
    {byte, :continue} ->
      defp object(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        [key, acc | stack] = stack
        final = [{key, value} | acc]
        continue(rest, original, skip + 1, stack, :maps.from_list(final))
      end
    {byte, :key} ->
      defp object(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        [key, acc | stack] = stack
        acc = [{key, value} | acc]
        key(rest, original, skip + 1, [acc | stack])
      end
    {byte, :error} ->
      defp object(<<unquote(byte), _rest::bits>>, original, skip, _stack, _value) do
        error(original, skip)
      end
  end)
  defp object(<<_rest::bits>>, original, skip, _stack, _value) do
    error(original, skip)
  end

  ranges = [{'\s\n\t\r', :key}, {hd('}'), :continue}, {?\", :string}]
  key_jt = Codegen.jump_table(ranges, :error)

  Enum.map(key_jt, fn
    {byte, :key} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack) do
        key(rest, original, skip + 1, stack)
      end
    {byte, :continue} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack) do
        case stack do
          [[] | stack] ->
            continue(rest, original, skip + 1, stack, %{})
          _ ->
            error(original, skip)
        end
      end
    {byte, :string} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack) do
        string(rest, original, skip + 1, [@key | stack], 0)
      end
    {byte, :error} ->
      defp key(<<unquote(byte), _rest::bits>>, original, skip, _stack) do
        error(original, skip)
      end
  end)
  defp key(<<_rest::bits>>, original, skip, _stack) do
    error(original, skip)
  end

  ranges = [{'\s\n\t\r', :key}, {?:, :value}]
  key_jt = Codegen.jump_table(ranges, :error)

  Enum.map(key_jt, fn
    {byte, :key} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        key(rest, original, skip + 1, stack, value)
      end
    {byte, :value} ->
      defp key(<<unquote(byte), rest::bits>>, original, skip, stack, value) do
        value(rest, original, skip + 1, [@object, value | stack])
      end
    {byte, :error} ->
      defp key(<<unquote(byte), _rest::bits>>, original, skip, _stack, _value) do
        error(original, skip)
      end
  end)
  defp key(<<_rest::bits>>, original, skip, _stack, _value) do
    error(original, skip)
  end

  defp null(<<"ull", rest::bits>>, original, skip, stack) do
    continue(rest, original, skip + 3, stack, nil)
  end
  defp null(<<_rest::bits>>, original, skip, _stack) do
    error(original, skip)
  end

  defp value_true(<<"rue", rest::bits>>, original, skip, stack) do
    continue(rest, original, skip + 3, stack, true)
  end
  defp value_true(<<_rest::bits>>, original, skip, _stack) do
    error(original, skip)
  end

  defp value_false(<<"alse", rest::bits>>, original, skip, stack) do
    continue(rest, original, skip + 4, stack, false)
  end
  defp value_false(<<_rest::bits>>, original, skip, _stack) do
    error(original, skip)
  end

  ranges = [{?\", :continue}, {?\\, :escape}, {0x00..0x1F, :error}]
  string_jt = Codegen.jump_table(ranges, :string, 128)

  Enum.map(string_jt, fn
    {byte, :continue} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, len) do
        string = binary_part(original, skip, len)
        continue(rest, original, skip + len + 1, stack, string)
      end
    {byte, :escape} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, len) do
        part = binary_part(original, skip, len)
        escape(rest, original, skip + len, stack, part)
      end
    {byte, :string} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, len) do
        string(rest, original, skip, stack, len + 1)
      end
    {byte, :error} ->
      defp string(<<unquote(byte), _rest::bits>>, original, skip, _stack, _len) do
        error(original, skip)
      end
  end)
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, len)
       when char <= 0x7FF do
    string(rest, original, skip, stack, len + 2)
  end
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, len)
       when char <= 0xFFFF do
    string(rest, original, skip, stack, len + 3)
  end
  defp string(<<_char::utf8, rest::bits>>, original, skip, stack, len) do
    string(rest, original, skip, stack, len + 4)
  end
  defp string(<<_rest::bits>>, original, skip, _stack, len) do
    error(original, skip + len)
  end

  Enum.map(string_jt, fn
    {byte, :continue} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, acc, len) do
        last = binary_part(original, skip, len)
        string = IO.iodata_to_binary([acc | last])
        continue(rest, original, skip + len + 1, stack, string)
      end
    {byte, :escape} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, acc, len) do
        part = binary_part(original, skip, len)
        escape(rest, original, skip + len, stack, [acc | part])
      end
    {byte, :string} ->
      defp string(<<unquote(byte), rest::bits>>, original, skip, stack, acc, len) do
        string(rest, original, skip, stack, acc, len + 1)
      end
    {byte, :error} ->
      defp string(<<unquote(byte), _rest::bits>>, original, skip, _stack, _acc, _len) do
      error(original, skip)
    end
  end)
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, acc, len)
       when char <= 0x7FF do
    string(rest, original, skip, stack, acc, len + 2)
  end
  defp string(<<char::utf8, rest::bits>>, original, skip, stack, acc, len)
       when char <= 0xFFFF do
    string(rest, original, skip, stack, acc, len + 3)
  end
  defp string(<<_char::utf8, rest::bits>>, original, skip, stack, acc, len) do
    string(rest, original, skip, stack, acc, len + 4)
  end
  defp string(<<_rest::bits>>, original, skip, _stack, _acc, len) do
    error(original, skip + len)
  end

  escapes = Enum.zip('\b\t\n\f\r"\\/', 'btnfr"\\/')

  for {byte, escape} <- escapes do
    defp escape(<<unquote(escape), rest::bits>>, original, skip, stack, acc) do
      string(rest, original, skip + 2, stack, [acc, unquote(byte)], 0)
    end
  end
  defp escape(<<?u, rest::bits>>, original, skip, stack, acc) do
    escapeu(rest, original, skip, stack, acc)
  end
  defp escape(<<_rest::bits>>, original, skip, _stack, _acc) do
    error(original, skip + 1)
  end

  defp escapeu(<<escape::binary-4, rest::bits>>, original, skip, stack, acc) do
    hi = try_parse_hex(escape, skip)
    if not hi in 0xD800..0xDBFF do
      codepoint = try_codepoint(hi, escape, skip)
      string(rest, original, skip + 6, stack, [acc, codepoint], 0)
    else
      escape_surrogate(rest, original, skip, stack, acc, hi)
    end
  end
  defp escapeu(<<_rest::bits>>, original, skip, _stack, _acc) do
    error(original, skip + 2)
  end

  defp escape_surrogate(<<?\\, ?u, escape::binary-4, rest::bits>>, original, skip, stack, acc, hi) do
    lo = try_parse_hex(escape, skip + 6)
    if lo in 0xDC00..0xDFFF do
      codepoint = 0x10000 + ((hi &&& 0x03FF) <<< 10) + (lo &&& 0x03FF)
      string(rest, original, skip + 12, stack, [acc, <<codepoint::utf8>>], 0)
    else
      token = binary_part(original, skip, 12)
      token_error(token, skip)
    end
  end
  defp escape_surrogate(<<_rest::bits>>, original, skip, _stack, _acc, _hi) do
    error(original, skip + 10)
  end

  defp try_codepoint(codepoint, string, position) do
    <<codepoint::utf8>>
  rescue
    ArgumentError ->
      token_error("\\u" <> string, position)
  end

  defp try_parse_hex(string, position) do
    String.to_integer(string, 16)
  rescue
    ArgumentError ->
      token_error("\\u" <> string, position)
  end

  defp try_parse_float(string, token, skip) do
    String.to_float(string)
  rescue
    ArgumentError ->
      token_error(token, skip)
  end

  defp error(<<_rest::bits>>, original, skip, _stack) do
    error(original, skip - 1)
  end

  defp error(_original, skip) do
    throw {:position, skip}
  end

  defp token_error(token, position) do
    throw {:token, token, position}
  end

  defp continue(<<rest::bits>>, original, skip, [next | stack], value) do
    case next do
      @terminate -> terminate(rest, original, skip, stack, value)
      @array     -> array(rest, original, skip, stack, value)
      @key       -> key(rest, original, skip, stack, value)
      @object    -> object(rest, original, skip, stack, value)
    end
  end

  defp terminate(<<byte, rest::bits>>, original, skip, stack, value)
       when byte in '\s\n\r\t' do
    terminate(rest, original, skip + 1, stack, value)
  end
  defp terminate(<<>>, _original, _skip, _stack, value) do
    value
  end
  defp terminate(<<_rest::bits>>, original, skip, _stack, _value) do
    error(original, skip)
  end
end
