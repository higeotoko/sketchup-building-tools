# frozen_string_literal: true

require_relative '../extension/sbr_architecture/layout'
require_relative '../extension/sbr_architecture/openings'

openings = Higeotoko::SbrArchitecture::Openings
door = { 'kind' => 'door', 'width' => 901, 'height' => 2000, 'offset' => 1450, 'sill' => 0 }
raise 'A legacy door should remain an opening' if openings.swing_path(door, 60, -60)
raise 'Odd millimetre width was truncated' unless openings.position(door).first(2) == [999.5, 1900.5]
%w[start end].product(%w[left right]).each do |end_point, side|
  values = door.merge('swing' => "#{end_point}_#{side}")
  settings = openings.parameters('door', values).merge('offset' => door.fetch('offset'))
  hinge, arc = openings.swing_path(settings, 60, -60)
  x = end_point == 'start' ? 999.5 : 1900.5
  closed = end_point == 'start' ? 1900.5 : 999.5
  y = side == 'left' ? 60 : -60
  raise 'Wrong door hinge or closed edge' unless hinge == [x, y] && arc.first == [closed, y]
  raise 'Door did not open to the specified side' unless arc.last.map { |value| value.round(6) } == [x, y + (side == 'left' ? 901 : -901)]
end

begin
  openings.parameters('door', door.merge('swing' => 'guess'))
  raise 'Invalid door swing was accepted'
rescue ArgumentError => e
  raise unless e.message.include?('開き勝手')
end

types = Higeotoko::SbrArchitecture::Doors
points = [[0, 0], [4000, 0]]
profiles = [[[0, 60], [0, -60], [4000, -60], [4000, 60]]]
wall = { 'points' => points, 'height' => 2700, 'thickness' => 120 }
fixture = door.merge('segment' => 0, 'offset' => 1900, 'width' => 1000)
types::TYPES.each_key do |type|
  key = types.direction_key('door_type' => type)
  settings = fixture.merge('door_type' => type)
  settings[key] = %w[double split].include?(type) ? 'start_right' : 'end_right' if key
  opening = fixture.merge(openings.parameters('door', settings))
  openings.validate(wall.merge('openings' => [opening]), profiles)
  paths = openings.symbol_paths(opening, 60, -60, points)
  count = { 'single' => 4, 'double' => 6, 'unequal' => 6, 'surface' => 5, 'bypass' => 4, 'split' => 7, 'fold' => 4, 'empty' => 0 }
  raise "Wrong plan symbol for #{type}" unless paths.size == count.fetch(type)
  if %w[surface bypass split fold].include?(type)
    raise 'A sliding or folding door acquired a swing arc' if openings.swing_path(opening, 60, -60)
  end
  next unless types.filled?(opening)

  boxes = types.leaf_boxes(opening, 60, -60)
  raise 'A leaf collapsed' unless boxes.all? { |a, b| a.zip(b).all? { |min, max| max > min } }
  raise 'A surface door was buried in the wall' if type == 'surface' && boxes.first.last[1] >= -60
  if type == 'unequal'
    raise 'Parent and child widths were exchanged' unless types.panes(opening).first == [1400, 1700]
    raise 'Parent and child leaves are indistinguishable' unless boxes[0][1][0] - boxes[0][0][0] < boxes[1][1][0] - boxes[1][0][0]
    closed = openings.symbol_paths(opening.merge('swing' => 'none'), 60, -60, points)
    raise 'Closed parent/child joint was lost' unless closed.size == 4 && closed[0].last[0] < closed[1].first[0]
  end
end

slide = fixture.merge('door_type' => 'surface', 'motion' => 'end_right')
begin
  openings.validate(wall.merge('openings' => [slide.merge('offset' => 3000)]), profiles)
  raise 'A door moved through the wall end'
rescue ArgumentError => e
  raise unless e.message.include?('引き代')
end
begin
  other = fixture.merge('kind' => 'window', 'offset' => 3100, 'width' => 400, 'sill' => 900, 'height' => 1000)
  openings.validate(wall.merge('openings' => [slide, other]), profiles)
  raise 'A door moved through another opening'
rescue ArgumentError => e
  raise unless e.message.include?('引き代')
end
puts 'Door formats, clearance, legacy swing and exact width checks passed'
