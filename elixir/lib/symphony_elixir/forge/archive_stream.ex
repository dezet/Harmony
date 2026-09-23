defmodule SymphonyElixir.Forge.ArchiveStream do
  @moduledoc false

  @spec into(non_neg_integer(), atom()) :: function()
  def into(max_bytes, stream_key)
      when is_integer(max_bytes) and max_bytes >= 0 and is_atom(stream_key) do
    fn {:data, chunk}, {request, response} when is_binary(chunk) ->
      state = Map.get(response.private, stream_key, %{bytes: 0, chunks: [], too_large?: false})
      next_size = state.bytes + byte_size(chunk)

      cond do
        state.too_large? ->
          {:halt, {request, response}}

        next_size > max_bytes ->
          next_state = %{state | too_large?: true}
          next_response = put_stream_state(response, stream_key, next_state)
          {:halt, {request, next_response}}

        true ->
          next_state = %{state | bytes: next_size, chunks: [chunk | state.chunks]}
          next_response = put_stream_state(response, stream_key, next_state)
          {:cont, {request, next_response}}
      end
    end
  end

  defp put_stream_state(response, stream_key, state) do
    %{response | body: state.chunks, private: Map.put(response.private, stream_key, state)}
  end
end
