defmodule NPM.HTTPClient do
  @moduledoc """
  Buffered npm HTTP requests using `http_fetch`.

  JSON responses are decoded by content type unless `decode_body: false` is set.
  Transport failures return errors; HTTP status codes remain available to callers,
  which own retry and registry-origin policies.

  `:max_body_bytes` rejects a response with `{:error, {:body_too_large, limit}}`
  when its declared `content-length` or its buffered body exceeds the limit.
  """

  @doc "Perform a GET request."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(url, opts \\ []), do: request(:get, url, opts)

  @doc "Perform a POST request."
  @spec post(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, opts \\ []), do: request(:post, url, opts)

  @doc "Perform a PUT request."
  @spec put(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(url, opts \\ []), do: request(:put, url, opts)

  defp request(method, url, opts) do
    headers = Enum.map(opts[:headers] || [], fn {name, value} -> {to_string(name), value} end)

    headers =
      if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "accept-encoding" end) do
        headers
      else
        [{"accept-encoding", "gzip, deflate"} | headers]
      end

    {body, headers} =
      if Keyword.has_key?(opts, :json) do
        {JSON.encode!(opts[:json]), [{"content-type", "application/json"} | headers]}
      else
        {opts[:body], headers}
      end

    options = [
      method: method,
      headers: headers,
      body: body,
      timeout: Keyword.get(opts, :timeout, 15_000),
      connect_timeout: Keyword.get(opts, :connect_timeout, 30_000),
      redirect: redirect_mode(Keyword.get(opts, :redirect, true))
    ]

    case HTTP.fetch(url, options) |> HTTP.Promise.await() do
      %HTTP.Response{} = response ->
        limit = opts[:max_body_bytes]

        with :ok <- check_size(declared_length(response), limit),
             {:ok, body} <- read_body(response),
             :ok <- check_size(byte_size(body), limit),
             {:ok, body} <- decode_body(body, response, opts) do
          {:ok, %{status: response.status, headers: response.headers.headers, body: body}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp check_size(size, limit) when is_integer(size) and is_integer(limit) and size > limit,
    do: {:error, {:body_too_large, limit}}

  defp check_size(_size, _limit), do: :ok

  defp declared_length(response) do
    with value when is_binary(value) <- HTTP.Response.get_header(response, "content-length"),
         {length, ""} <- Integer.parse(String.trim(value)) do
      length
    else
      _ -> nil
    end
  end

  defp redirect_mode(true), do: :follow
  defp redirect_mode(false), do: :manual

  defp read_body(response) do
    {:ok, HTTP.Response.read_all(response)}
  rescue
    error in HTTP.ResponseError -> {:error, error.reason}
    error in RuntimeError -> {:error, error}
  end

  defp decode_body(body, response, opts) do
    {content_type, _params} = HTTP.Response.content_type(response)

    if Keyword.get(opts, :decode_body, true) and
         (content_type == "application/json" or String.ends_with?(content_type, "+json")) do
      NPM.JSON.decode(body)
    else
      {:ok, body}
    end
  end
end
