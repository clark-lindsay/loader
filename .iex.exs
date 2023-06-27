alias Loader.{LoadProfile, WorkResponse, WorkSpec, LoadProfile.Curves}

service_request_spec = %WorkSpec{
  task: fn req_count ->
    Loader.send_requests(:get, "http://localhost:3000/services", count: req_count)
  end,
  is_success?: fn %WorkResponse{response: res} ->
    case res do
      {:ok, _any} -> true
      _any -> false
    end
  end
}

profiles = %{
  default: LoadProfile.new(),
  three_k_uniform: LoadProfile.new(%{function: fn _x -> 300 end}),
  ten_k_uniform: LoadProfile.new(%{function: fn _x -> 1_000 end})
}
