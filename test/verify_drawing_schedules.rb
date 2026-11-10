# frozen_string_literal: true

require 'json'
require_relative '../extension/sbr_architecture/openings'
require_relative '../extension/sbr_architecture/rooms'
require_relative '../extension/sbr_architecture/drawing_schedules'

module Sketchup
  Group = Struct.new(:kind, :parameters)
end

module Higeotoko::SbrArchitecture
  def self.levels(_model) = { '1FL' => 450, '2FL' => 3450, '10FL' => 27450 }

  module Follow
    def self.kind(group) = group.kind
    def self.parameters(group) = group.parameters
  end
end

model = Struct.new(:entities).new([])
groups = model.entities
window = { 'kind' => 'window', 'mark' => 'AW-01', 'width' => 1650, 'height' => 1100, 'sill' => 900,
           'window_type' => 'sliding', 'mounting' => { 'mode' => 'inset', 'offset' => 30, 'side' => 'auto' } }
door = { 'kind' => 'door', 'mark' => 'WD-01', 'width' => 950, 'height' => 2000,
         'door_type' => 'unequal', 'inactive_width' => 300, 'swing' => 'end_right' }
groups << Sketchup::Group.new('wall', { 'level' => '1FL', 'openings' => [window, window, door] })
groups << Sketchup::Group.new('wall', { 'level' => '2FL', 'openings' => [window.merge('width' => 1800)] })
groups << Sketchup::Group.new('wall', { 'level' => '10FL', 'openings' => [door.merge('mark' => '')] })
groups << Sketchup::Group.new('room', { 'level' => '1FL', 'room_name' => '居間・食堂', 'area' => 14.126 })
groups << Sketchup::Group.new('room', { 'level' => '1FL', 'room_name' => '玄関', 'area' => 3.166 })
groups << Sketchup::Group.new('room', { 'level' => '2FL', 'room_name' => '洋室' })
tables = Higeotoko::SbrArchitecture::DrawingSchedules

openings, note = tables.opening_rows(model, Higeotoko::SbrArchitecture.levels(model))
raise 'Opening quantity or floor order was lost' unless openings.map { |row| row.values_at(0, 1, 7) } ==
                                                        [%w[1FL AW-01 2], %w[1FL WD-01 1], %w[2FL AW-01 1], %w[10FL 未入力 1]]
raise 'Repeated marks with different sizes were not flagged' unless openings.count { |row| row.last.include?('異なる仕様') } == 2
raise 'A construction specification was lost' unless openings[0].last.include?('インセット 30 mm') && openings[1].last.include?('子扉 300 mm')
raise 'Door incorrectly shows a window sill' unless openings[1][6].empty?
raise 'Opening summary is wrong' unless note.include?('5箇所')
rooms, note = tables.room_rows(model, Higeotoko::SbrArchitecture.levels(model))
raise 'Incomplete rooms entered the numeric area column' unless rooms.last == ['2FL', '洋室', '', '室境界を確認']
raise 'Room total disagrees with displayed rows' unless note.include?('17.30 m²') && note.include?('未確定 1件')
raise 'Tables must be opt-in' unless tables.pages(model, []).empty?
raise 'Empty schedules lack a readable row' unless tables.paginate([], [392]).first.first.last == [['登録なし']]
sample = tables.pages(model, %w[rooms openings])
raise 'Schedules conflict with drawing sheet numbers' unless sample.map(&:first) == %w[T-01 T-02]

130.times do |i|
  groups << Sketchup::Group.new('room', { 'level' => '1FL', 'room_name' => "長い室名#{i}" * 12, 'area' => 1.2 })
end
long = '室名' * 1600
groups << Sketchup::Group.new('room', { 'level' => '2FL', 'room_name' => long })
pages = tables.pages(model, ['rooms'])
raise 'The second page lacks a distinct sheet number' unless pages[1].first == 'T-02-02'
raise 'A table exceeded the A3 frame' unless pages.all? do |_, _, _, _, widths, rows|
  widths.sum == 392 && rows.any? && rows.all? { |y, height, _| y >= tables::TOP && y + height <= tables::BOTTOM }
end
raise 'Long text was lost at the page break' unless pages.flat_map(&:last).flat_map { |_, _, cells| cells[1] }.join.include?(long)
File.write(ARGV.first, JSON.generate(sample), encoding: 'UTF-8') if ARGV.first
puts 'Schedules preserve quantity, level order, conflicting marks, room totals and A3 pagination'
