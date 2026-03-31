defmodule GreenGrassLite.MqttHintTest do
  use ExUnit.Case

  alias GreenGrassLite.MqttHint

  test "from_lines/1 :pending without connect line" do
    assert MqttHint.from_lines(["I[iotcored] boot"]) == :pending
  end

  test "from_lines/1 :connected after connect without later disconnect" do
    lines = [
      "I[iotcored] mqtt.c:339: Connected to IoT core at foo.iot.amazonaws.com."
    ]

    assert MqttHint.from_lines(lines) == :connected
  end

  test "from_lines/1 :disconnected when failure after last connect" do
    lines = [
      "I[iotcored] Connected to IoT core at x.",
      "E[iotcored] Error in receive loop, closing connection."
    ]

    assert MqttHint.from_lines(lines) == :disconnected
  end

  test "from_lines/1 :connected when disconnect is before last connect in tail" do
    lines = [
      "E[iotcored] Connection failed: x",
      "I[iotcored] Connected to IoT core at y."
    ]

    assert MqttHint.from_lines(lines) == :connected
  end
end
