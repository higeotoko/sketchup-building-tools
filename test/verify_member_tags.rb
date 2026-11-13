# frozen_string_literal: true

PAGE_USE_CAMERA = 1
PAGE_USE_SECTION_PLANES = 2
PAGE_USE_LAYER_VISIBILITY = 4
PAGE_USE_HIDDEN_OBJECTS = 8
PAGE_USE_RENDERING_OPTIONS = 16
ALeaderModel = 2
Z_AXIS = :vertical

%w[layout column_cuts framing_plan drawings].each do |name|
  require_relative "../extension/sbr_architecture/#{name}"
end

class Numeric
  def to_mm = self
  def mm = self
end

Point = Struct.new(:x, :y, :z) do
  def transform(placement)
    a, b = placement.turned ? [-y, x] : [x, y]
    Point.new(a + placement.x, b + placement.y, z)
  end

  def parallel?(_axis) = x.zero? && y.zero?
end
Placement = Struct.new(:x, :y, :turned) do
  def origin = Point.new(x, y, 0)
  def zaxis = Point.new(0, 0, 1)
end
Layer = Struct.new(:visible?)
Box = Struct.new(:min, :max) { def valid? = true }
Member = Struct.new(:persistent_id, :kind, :parameters, :transformation, :bounds, :layer)
Mark = Struct.new(:label, :point, :vector, :leader_type, :arrow_type, :font)

module Geom
  Vector3d = Point
end
module Sketchup
  module Dimension
    ARROW_DOT = 2
  end
end
module Higeotoko::SbrArchitecture
  def self.point(x, y, z = 0) = Point.new(x, y, z)
  def self.levels(_model) = { '1FL' => 0, '2FL' => 3000 }
  def self.steel_member(_kind, params) = params
  def self.steel_section_ends(_member)
    [[point(0, -75), point(0, 75)], [point(3000, -75), point(3000, 75)]]
  end

  module Catalog
    SYSTEMS = { 'timber' => '木造', 'steel' => '鉄骨造', 'rc' => 'RC造' }.freeze
  end
  module Follow
    def self.kind(group) = group.kind
    def self.parameters(group) = group.parameters
  end
  module LayerHatches
    def self.boundary(column, transform, _axis, _cut, _projection)
      half = column.parameters.fetch('width') / 2.0
      corners = [[-half, -half], [half, -half], [half, half], [-half, half]].map do |x, y|
        Point.new(x, y, 0).transform(transform).to_a.first(2)
      end
      corners.zip(corners.rotate)
    end
  end
end

def member(id, kind, params, placement, low, high, visible: true)
  Member.new(id, kind, params, placement, Box.new(Point.new(0, 0, low), Point.new(0, 0, high)), Layer.new(visible))
end

api = Higeotoko::SbrArchitecture
tags = api::MemberTags
steel = { 'system' => 'steel', 'section_id' => 'H-300x150x6.5x9', 'end' => [0, 3000] }
beam = member(1, 'beam', steel, Placement.new(500, 0, true), 2700, 3000)
column = member(2, 'column', { 'system' => 'rc', 'width' => 400, 'depth' => 450 }, Placement.new(500, 1000, false), 0, 3000)
above = member(3, 'beam', steel, Placement.new(1500, 0, true), 3100, 3400)
hidden = member(4, 'beam', steel, Placement.new(2500, 0, true), 2700, 3000, visible: false)
groups = [beam, column, above, hidden]
plan = { 'kind' => 'plan', 'level' => '1FL' }
framing = { 'kind' => 'framing', 'level' => '2FL', 'top_tolerance' => 100 }
raise 'General plan tagged a beam above its cut' unless tags.candidates(nil, plan, 1100, Set.new, groups).keys == [2]
overhead = tags.candidates(nil, plan.merge('plan_top' => 3000), 1100, Set.new, groups)
raise 'Headroom range or tag visibility was ignored' unless overhead.keys.sort == [1, 2]
found = tags.candidates(nil, framing, 3000, Set.new, groups)
raise 'Framing tags did not follow beam and column visibility' unless found.keys == [1, 2]
raise 'A hidden member was pickable' unless tags.candidates(nil, framing, 3000, Set[2], groups).keys == [1]
raise 'Steel axis is not along the local extrusion' unless found[1].axis == [[500, 0], [500, 3000]]
raise 'A column overlapping a beam did not take priority' unless tags.pick([500, 1000], found.values, 80, nil).first.id == 2
hit, station = tags.pick([500, 2400], found.values, 80, nil)
raise 'Beam position was not stored as a fraction' unless hit.id == 1 && station == 0.8
raise 'A member outside the crop was selected' if tags.pick([500, 2400], found.values, 80, [0, 0, 2000, 1800])

entities = Class.new(Array) do
  def add_text(label, point, vector)
    mark = Mark.new(label, point, vector)
    self << mark
    mark
  end
end.new
entry = { 'id' => 'beam-label', 'member_id' => 1, 'station' => station, 'offset' => [400, 0] }
missing = { 'id' => 'deleted-label', 'member_id' => 999, 'station' => 0, 'offset' => [200, 0] }
values, masks, tagged = tags.draw(entities, 3000, nil, [entry, missing], found, 50)
raise 'Structural labels or reference tracking are wrong' unless
  values == { 'beam-label' => '梁｜鉄骨造 H-300x150x6.5x9', 'deleted-label' => nil } && tagged == [1] && masks.size == 1
mark = entities.last
raise 'A leader did not attach to the picked location' unless
  mark.point == Point.new(500, 2400, 2999.88) && mark.vector == Point.new(400, 0, 0) && mark.leader_type == ALeaderModel

beam.transformation.x = 800
beam.parameters['section_id'] = 'H-350x175x7x11'
revised = tags.candidates(nil, framing, 3000, Set.new, groups, ids: Set[1])
values, = tags.draw(entities, 3000, nil, [entry], revised, 50)
raise 'Tags must update their section and move with the member' unless values['beam-label'].end_with?('H-350x175x7x11') &&
                                                                  entities.last.point.x == 800
values, = tags.draw(entities, 3000, [0, 0, 1400, 3000], [entry], revised, 50)
raise 'Text outside the partial plan was accepted' unless values['beam-label'].nil?
raise 'Column size is wrong' unless found[2].text == '柱｜RC造 400×450'
puts 'Member tag selection, steel axis, leaders, size changes, moved and deleted members, and crop checks passed'
