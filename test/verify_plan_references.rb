# frozen_string_literal: true

%w[plan_references plan_range column_cuts framing_plan].each do |name|
  require_relative "../extension/sbr_architecture/#{name}"
end

module Sketchup
  Color = Struct.new(:r, :g, :b)

  module Dimension
    ARROW_NONE = 0
  end
end

class Numeric
  def mm = self
end

module Geom
  Vector3d = Struct.new(:x, :y, :z) do
    def to_json(*) = to_a.to_json
  end
end
ALeaderModel = 2

module Higeotoko::SbrArchitecture
  def self.point(*coordinates) = coordinates

  module Drawings
    META = 'test'
    def self.sheet_label(number)
      format('A-%02d', number) if number
    end
  end
end

api = Higeotoko::SbrArchitecture
refs = api::PlanReferences
host = { 'kind' => 'plan', 'key' => 'plan:1FL', 'level' => '1FL' }
part = { 'kind' => 'plan', 'key' => 'part-a', 'level' => '1FL', 'plan_name' => '水回り詳細', 'plan_crop' => [900, 1200, 3900, 3500] }
part_b = part.merge('key' => 'part-b', 'plan_name' => '建具詳細')
other = part.merge('key' => 'part-2fl', 'level' => '2FL')
numbers = { 'part-a' => 9, 'part-b' => 10, 'part-2fl' => 11 }
targets = refs.targets([other, part_b, host, part], numbers)
mine = refs.for_plan(host, targets)
raise 'Part drawing numbers or level filtering are wrong' unless mine.map { |item| item['sheet'] } == %w[A-09 A-10]
raise 'A partial plan generated a recursive mark' unless refs.for_plan(part, targets).empty?
named = host.merge('key' => 'full-view', 'plan_name' => '全体確認')
raise 'Named full plans should be opt-in' unless refs.for_plan(named, targets).empty?
raise 'Named full plan could not enable marks' unless refs.for_plan(named.merge('show_partial_refs' => true), targets) == mine
raise 'Standard plan could not hide marks' unless refs.for_plan(host.merge('show_partial_refs' => false), targets).empty?
raise 'An old standard plan changed its default' unless refs.settings({}, host, nil).empty?
raise 'A cropped view saved a setting for marks' unless refs.settings({ 'show_partial_refs' => true }, part, part['plan_crop']).empty?

page = Struct.new(:attributes) do
  def get_attribute(_dictionary, key, default) = attributes.fetch(key, default)
end.new({})
raise 'A legacy plan with no parts needs no regeneration' if refs.stale?(page, host, [])
raise 'The first registered part did not invalidate its full plan' unless refs.stale?(page, host, targets)
page.attributes[refs::SIGNATURE] = refs.signature(mine)
raise 'Reordering changed the dependency fingerprint' if refs.stale?(page, host, targets.reverse)
changed = part.merge('plan_name' => '水回り詳細 改訂', 'plan_crop' => [1000, 1300, 4100, 3600])
changed_targets = refs.targets([changed, part_b, other], numbers)
raise 'A moved and renamed partial drawing did not invalidate its full plan' unless refs.stale?(page, host, changed_targets)
raise 'The moved partial drawing lost its drawing number' unless changed_targets.first['sheet'] == 'A-09'
raise 'Deleting a partial plan did not invalidate the reference' unless refs.stale?(page, host, refs.targets([part_b, other], numbers))
raise 'An edit on another floor invalidated the host' if refs.stale?(page, host, refs.targets([part, part_b], numbers))

Mark = Struct.new(:text, :point, :end_point, :material, :font, :layer, :leader_type, :arrow_type)
Ink = Struct.new(:color)
Materials = Class.new(Hash) do
  def add(name) = self[name] = Ink.new
end
Entities = Class.new(Array) do
  def add_line(a, b)
    raise 'Empty callout stroke' if a == b

    mark = Mark.new(nil, a, b)
    self << mark
    mark
  end

  def add_text(text, point, vector)
    mark = Mark.new(text, point, vector)
    self << mark
    mark
  end
end
Group = Struct.new(:entities, :model)
Model = Struct.new(:materials, :layers)
group = Group.new(Entities.new, Model.new(Materials.new, [:untagged]))
[50, 100].each do |scale|
  group.entities.clear
  masks = refs.draw(group, mine, 1100, scale, [])
  raise 'References with the same crop overlapped' if api::FramingPlan.overlaps_label?(*masks)
  raise 'Drawing numbers are absent from the callouts' unless group.entities.filter_map(&:text) == %w[A-09｜水回り詳細 A-10｜建具詳細]
  first_label = group.entities.find(&:text)
  raise 'The reference label is not tied to the crop corner' unless
    first_label.point == [3900, 3500, 1099.8] && first_label.leader_type == ALeaderModel && first_label.end_point.to_a == [-3 * scale, 3 * scale, 0]
  edges = group.entities.reject(&:text)
  raise 'Dash scale does not stay constant on the page' unless edges.any? do |edge|
    x, y, z = edge.point
    u, v, = edge.end_point
    [1200, 3500].include?(y) && v == y && z == 1099.8 && ((u - x).abs - 3 * scale).abs < 0.001
  end
  raise 'Reference geometry was put on an unrelated tag' unless group.entities.all? { |entity| entity.layer == :untagged }
end

wall = [[-1000, 5300], [8000, 5300]]
anchor, _, label_mask = refs.label_bounds([1400, 2600, 3500, 4900], 'A-09｜水回り詳細', 100, [], [wall])
raise 'The 1:100 callout did not move away from the wall' unless anchor[1] == 2600 &&
  !api::ColumnCuts.intersects?(*wall, [label_mask])

puts 'Partial-plan references track floor, name, crop, drawing number, deletion and paper-size callouts'
