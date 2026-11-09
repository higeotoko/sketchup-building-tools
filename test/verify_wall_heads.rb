# frozen_string_literal: true

require 'json'

# This fixture evaluates the saved rules in millimetres. SketchUp geometry
# creation, Undo, and native file export require a separate SketchUp run.
class Numeric
  def to_mm = self
end

module Geom
  Point3d = Struct.new(:x, :y, :z) do
    def transform(placement) = self.class.new(x + placement.x, y + placement.y, z + placement.z)
    def -(other) = self.class.new(x - other.x, y - other.y, z - other.z)
    def parallel?(_axis) = x.zero? && y.zero?
  end

  def self.tesselate(points)
    points[1..].each_cons(2).flat_map { |a, b| [points.first, a, b] }
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0)
Z_AXIS = Geom::Point3d.new(0, 0, 1)
Transform = Struct.new(:x, :y, :z) do
  def inverse = self.class.new(-x, -y, -z)
  def origin = Geom::Point3d.new(x, y, z)
end

module Sketchup
  Bounds = Struct.new(:min) do
    def valid? = true
  end

  class Group
    attr_accessor :transformation, :params, :base
    attr_reader :persistent_id, :model, :name

    def initialize(model, id, kind, params, z)
      @model, @persistent_id, @kind, @params = model, id, kind, params
      @transformation = Transform.new(0, 0, z)
      @base = z
      @name = "#{kind}-#{id}"
      model.entities << self
    end

    def locked? = false
    def bounds = Bounds.new(Geom::Point3d.new(0, 0, @base))

    def get_attribute(_dict, key)
      key == 'kind' ? @kind : JSON.generate(@params)
    end
  end
end

Model = Struct.new(:entities) do
  def find_entity_by_persistent_id(id) = entities.find { |item| item.persistent_id == id }
end

%w[layout composition openings follow plan_linework wall_heads].each do |name|
  require_relative "../extension/sbr_architecture/#{name}"
end
api = Higeotoko::SbrArchitecture
module Higeotoko::SbrArchitecture
  DICT = 'test'
  def self.point(x, y, z = 0) = Geom::Point3d.new(x, y, z)
  def self.placement_for(group, _kind, _params) = group.transformation
  def self.object_name(kind) = kind
  def self.wall_profiles(params) = Layout.wall_profiles(*params.values_at('points', 'thickness', 'alignment'))
  def self.rebuild(group, _kind, params, _previous, _placement) = group.params = params
  def self.member_profile(_kind, params) = Layout.wall_profiles([[0.0, 0.0], params.fetch('end')], params.fetch('width'), '中央').first
end

model = Model.new([])
outline = [[0, 0], [7280, 0], [7280, 5460], [0, 5460], [0, 0]]
layers = [15, 105, 30].map { |thickness| { 'thickness' => thickness } }
opening = { 'segment' => 0, 'offset' => 2000, 'width' => 1800, 'height' => 1100, 'sill' => 800 }
plain = { 'points' => outline, 'alignment' => '中央', 'thickness' => 150, 'height' => 2650,
          'layers' => layers, 'openings' => [opening] }
wall = Sketchup::Group.new(model, 1, 'wall', plain, 0)
upper = Sketchup::Group.new(model, 2, 'wall', plain, 2940)
slab = Sketchup::Group.new(model, 3, 'slab', { 'points' => outline }, 2940)
slab.base = 2740
beam = Sketchup::Group.new(model, 4, 'beam', { 'width' => 105, 'end' => [7280, 0] }, 2770)
beam.base = 2530
head = api::WallHeads
check = ->(condition, name) { raise name unless condition; puts name }
failure = lambda do |message, &block|
  block.call
  raise "Expected rejection: #{message}"
rescue ArgumentError => error
  check.call(error.message.include?(message), error.message)
end

solve = ->(rule) { head.resolve(wall, plain.merge('head' => rule), wall.transformation) }
check.call(head.resolve(wall, plain, wall.transformation).equal?(plain), 'Fixed legacy walls keep their dimensions')
check.call(solve.call({ 'mode' => 'slab', 'stop' => '3' })['height'] == 2740, 'Floor stop follows actual underside')
check.call(solve.call({ 'mode' => 'beam', 'stop' => '4' })['height'] == 2530, 'Beam stop follows actual underside')
check.call(head.options(wall, %w[slab beam]).values == %w[3 4], 'Choose the floor first for exterior-wall continuity')
wall.params = solve.call({ 'mode' => 'beam', 'stop' => '4' })
beam.base = 2430
head.refresh(model, changed: beam)
check.call(wall.params.fetch('height') == 2430, 'Beam depth changes rebuild the attached wall')
rule = { 'mode' => 'exterior', 'stop' => '3', 'upper' => '2', 'side' => 'right' }
wall.params = solve.call(rule)
check.call((0..2).map { |i| head.layer_height(wall.params, i) } == [2740, 2740, 2940], 'Exterior layer alone continues to upper wall')
check.call(wall.params.fetch('openings') == plain.fetch('openings'), 'Opening identity and dimensions are preserved')
check.call(api::PlanLinework.slices(wall.params, 1100).sum { |_, openings, *| openings.size } == 1, 'Opening remains in its plan slice')
band = api::PlanLinework.slices(wall.params, 2800)
check.call(band.length == 4 && (band.first[3] - band.first[4]).abs == 30, 'Cut above the inside wall shows only the outer 30 mm')
check.call(api::PlanLinework.slices(wall.params, 2940).empty?, 'No cut at the outer wall top')
failure.call('開口が壁の端または天端') do
  lower_wall = wall.params.merge('height' => 1850)
  api::Openings.validate(lower_wall, api.wall_profiles(lower_wall))
end
failure.call('重なります') { solve.call(rule.merge('side' => 'left')) }
upper.transformation.x = 10
failure.call('そろっていません') { solve.call(rule) }
upper.transformation.x = 0
failure.call('参照先を選び直し') { solve.call(rule.merge('upper' => '99')) }
upper.transformation.z = 3150
slab.base = 2950
failure.call('納まりを更新') { head.check_current!(model) }
head.refresh(model, changed: slab)
check.call((0..2).map { |i| head.layer_height(wall.params, i) } == [2950, 2950, 3150], 'Floor and upper wall edits recalculate the two stops')
head.check_current!(model)
