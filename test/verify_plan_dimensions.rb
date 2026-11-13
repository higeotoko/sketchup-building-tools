# frozen_string_literal: true

require 'set'
require 'securerandom'
%w[layout openings doors wall_heads roof plan_linework plan_dimensions plan_dimension_placement].each do |name|
  require_relative "../extension/sbr_architecture/#{name}"
end

Point = Struct.new(:x, :y, :z) do
  def transform(placement) = Point.new(x + placement.x, y + placement.y, z + placement.z)
  def parallel?(_axis) = x.zero? && y.zero?
end
Placement = Struct.new(:x, :y, :z) do
  def inverse = Placement.new(-x, -y, -z)
  def origin = Point.new(x, y, z)
  def zaxis = Point.new(0, 0, 1)
  def xaxis = Point.new(0, 0, 1)
end
Z_AXIS = Point.new(0, 0, 1)
class Numeric
  def to_mm = self
  def mm = self
end
module Geom
  Vector3d = Point
  def self.intersect_line_plane(ray, _plane) = ray
end
module Sketchup
  Group = Struct.new(:persistent_id, :kind, :parameters, :transformation, :layer, :bounds)
  def self.set_status_text(_message, _bar); end
end
SB_PROMPT = 0
module Higeotoko::SbrArchitecture
  def self.point(x, y, z = 0) = Point.new(x, y, z)
  def self.wall_profiles(params) = Layout.wall_profile_for(params)

  module Follow
    def self.kind(group) = group.kind
    def self.parameters(group) = group.parameters
  end

  module PlanLinework
    def self.upright?(_placement) = true
  end

  module SectionPlacement
    def self.top_view?(_view) = true
  end
end
Model = Struct.new(:entities, :layers) do
  def find_entity_by_persistent_id(id) = entities.find { |entity| entity.persistent_id == id }
end
Box = Struct.new(:min, :max) { def valid? = true }
Layer = Struct.new(:visible?)
Dimension = Struct.new(:has_aligned_text, :layer)
Sink = Struct.new(:calls) do
  def add_dimension_linear(*points)
    calls << points
    Dimension.new
  end
end

api = Higeotoko::SbrArchitecture
dimensions = api::PlanDimensions
wall_settings = { 'points' => [[0, 0], [0, 4000]], 'thickness' => 120, 'alignment' => '中央', 'height' => 2700 }
layer = Layer.new(true)
first = Sketchup::Group.new(1, 'wall', wall_settings.dup, Placement.new(0, 0, 0), layer)
second = Sketchup::Group.new(2, 'wall', wall_settings.dup, Placement.new(3000, 0, 0), layer)
column = Sketchup::Group.new(3, 'column', { 'system' => 'steel' }, Placement.new(500, 2000, 0), layer,
                             Box.new(Point.new(350, 1850, 0), Point.new(650, 2150, 2700)))
model = Model.new([first, second, column], [layer])
cut = 1100
refs = dimensions.references(model, cut, Set.new)
a = refs.values.flatten.find { |anchor| anchor.ref['id'] == 1 && anchor.a.first == 60 }
b = refs.values.flatten.find { |anchor| anchor.ref['id'] == 2 && anchor.a.first == 2940 }
c = refs.values.flatten.find { |anchor| anchor.ref['id'] == 3 }
pair = [a.reference(0.5), b.reference(0.1)]
column_pair = [b.reference(0.1), c.reference(0)]
raise 'Wall measurements must be perpendicular to the second face' unless dimensions.endpoints(pair, refs) == [[60, 2000], [2940, 2000]]
raise 'A steel column should reference its center, in either pick order' unless
  dimensions.endpoints(column_pair, refs) == [[2940, 2000], [500, 2000]] &&
  dimensions.endpoints(column_pair.reverse, refs) == [[500, 2000], [2940, 2000]]

second.transformation.x += 250
second.parameters['thickness'] = 160
sink = Sink.new([])
entry = { 'id' => 'clear-width', 'refs' => pair, 'offset' => -300 }
result = dimensions.draw(sink, model, cut, {}, [entry], Set.new)
raise 'Wall moves and thickness edits should recalculate the dimension' unless result == { 'clear-width' => 3110 }
from, to, offset = sink.calls.last
raise 'The dimension placement moved to the wrong side' unless [from.x, to.x, offset.y] == [60, 3170, -300]
second.parameters.merge!('alignment' => api::Layout::ECCENTRIC, 'outside_side' => 'right',
                         'outer_offset' => 100, 'inner_offset' => 60)
raise 'An eccentric wall moved the reference to the centerline' unless dimensions.draw(sink, model, cut, {}, [entry], Set.new).values == [3130]
raise 'A hidden wall should not support an annotation' unless dimensions.draw(sink, model, cut, {}, [entry], Set[2]).values == [nil]
raise 'A dimension outside the crop was accepted' unless
  dimensions.draw(sink, model, cut, { 'plan_crop' => [0, 1900, 4000, 3000] }, [entry], Set.new).values == [nil]

second.parameters['openings'] = [{ 'segment' => 0, 'offset' => 2000, 'width' => 900,
                                   'sill' => 0, 'height' => 2000, 'kind' => 'door' }]
raise 'A dimension referenced a finish face removed by an opening' unless dimensions.draw(sink, model, cut, {}, [entry], Set.new).values == [nil]
model.entities.delete(second)
raise 'A deleted wall left a stale dimension' unless dimensions.draw(sink, model, cut, {}, [entry], Set.new).values == [nil]
raise 'Invalid dimensions should not create geometry' unless sink.calls.size == 2

page = Object.new
view = Struct.new(:tooltip) do
  def screen_coords(point) = Point.new(point.x / 10.0, point.y / 10.0, 0)
  def pickray(x, y) = Point.new(x * 10, y * 10, 1100)
  def invalidate; end
end.new
pages = Struct.new(:selected_page).new(page)
tool_model = Struct.new(:pages, :tool, :view) do
  def select_tool(_tool) = tool.deactivate(view)
end.new(pages, nil, view)
finished = []
tool_model.tool = api::PlanDimensionPlacement.new(tool_model, page, {}, cut, refs) { |value| finished << value }
tool_model.tool.onLButtonDown(0, 6, 200, view)
tool_model.tool.onLButtonDown(0, 294, 180, view)
tool_model.tool.onLButtonDown(0, 150, 170, view)
raise 'Three clicks did not register a dimension exactly once' unless finished.one? &&
  finished.first['refs'].map { |ref| ref['id'] } == [1, 2] && finished.first['offset'] == -300
finished.clear
tool_model.tool = api::PlanDimensionPlacement.new(tool_model, page, {}, cut, refs) { |value| finished << value }
tool_model.tool.onLButtonDown(0, 6, 200, view)
tool_model.tool.onCancel(0, view)
raise 'Esc persisted a partially placed dimension' unless finished == [nil]

puts 'Wall finishes, steel column centers, offset retention, moved walls, openings and missing references passed'
