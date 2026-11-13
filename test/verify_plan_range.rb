# frozen_string_literal: true

require 'set'
require_relative '../extension/sbr_architecture/layout'
require_relative '../extension/sbr_architecture/plan_range'

class Numeric
  def to_mm = self
end

module Higeotoko::SbrArchitecture::Follow
  def self.kind(group) = group.kind
end

Point = Struct.new(:z)
Box = Struct.new(:min, :max) do
  def valid? = !min.nil? && !max.nil?
end
Layer = Struct.new(:visible?)
Member = Struct.new(:kind, :persistent_id, :bounds, :layer)

def member(kind, id, bottom, top, visible: true)
  Member.new(kind, id, Box.new(Point.new(bottom), Point.new(top)), Layer.new(visible))
end

range = Higeotoko::SbrArchitecture::PlanRange
raise 'Legacy settings should retain the automatic plan' unless range.settings({}, 1100).empty?
raise 'Zero is a valid explicit floor limit' unless range.settings({ 'plan_bottom' => '0' }, 1100) == { 'plan_bottom' => 0 }
{ 'plan_bottom' => 1300, 'plan_top' => 1100 }.each do |field, value|
  begin
    range.settings({ field => value }, 1100)
  rescue ArgumentError
    next
  end
  raise "Invalid range accepted for #{field}"
end

# Absolute elevations for 1FL at +450, cut at +1550 and an upper limit at +3450.
slab = member('slab', 1, -25, 150)
footing = member('footing', 2, -500, 149)
cut_beam = member('beam', 3, 1500, 1800)
overhead = member('beam', 4, 3100, 3500)
at_limit = member('beam', 5, 3450, 3650)
above_limit = member('beam', 6, 3451, 3750)
hidden_beam = member('beam', 7, 2500, 2700)
hidden_tag = member('beam', 8, 2500, 2700, visible: false)
wall = member('wall', 9, 2500, 2700)
raise 'A slab whose surface meets the lower limit was lost' if range.outside?(slab, 150, 1550)
raise 'A part below the lower limit remained' unless range.outside?(footing, 150, 1550)
raise 'A beam cut by the plan was hidden' if range.outside?(cut_beam, 150, 1550)
raise 'An overhead beam would draw in solid lines' unless range.outside?(overhead, 150, 1550)
found = range.overhead_beams([slab, cut_beam, overhead, at_limit, above_limit, hidden_beam, hidden_tag, wall],
                             1550, 3450, Set[7])
raise 'Overhead selection included a cut, hidden, non-beam or out-of-range part' unless found == [overhead, at_limit]

[50, 100].each do |denominator|
  dashes = range.dash_spans([0, 0], [1000, 0], denominator)
  start, finish = dashes.first.map(&:first)
  gap = dashes[1].first[0] - finish
  raise "Dash sizes changed on paper at 1:#{denominator}" unless [(finish - start) / denominator, gap / denominator] == [3, 1.5]
  raise 'The last dash extends beyond the footprint' if dashes.last.last[0] > 1000
end
raise 'A zero-length edge produced a dash' unless range.dash_spans([5, 10], [5, 10], 50).empty?
puts 'Plan range limits, overhead selection and paper-space dash spacing passed'
