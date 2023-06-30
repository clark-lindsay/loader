alias Loader.{LoadProfile, WorkResponse, WorkSpec, LoadProfile.Curves}

service_request_spec = %WorkSpec{
  task: fn ->
      Finch.build(:get, "http://localhost:3000/services", [])
      |> Finch.request(Loader.Finch)
  end,
  is_success?: fn %WorkResponse{data: res} ->
    case res do
      {:ok, _any} -> true
      _any -> false
    end
  end
}

simple_math_spec = %WorkSpec{
  task: fn -> 2 + 2 end,
  is_success?: fn %WorkResponse{data: data} -> is_integer(data) end
}

profiles = %{
  default: LoadProfile.new(),
  three_k_uniform: LoadProfile.new(%{function: fn _x -> 300 end}),
  ten_k_uniform: LoadProfile.new(%{function: fn _x -> 1_000 end}),
  ten_x_linear: LoadProfile.new(%{function: &Curves.linear(&1, 10, 0)}),
  five_sine: LoadProfile.new(%{function: &Curves.sine_wave(&1, amplitude: 5)})
}
