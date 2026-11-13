# frozen_string_literal: true

require 'json'
require_relative '../extension/sbr_architecture/drawing_schedules'
require_relative '../extension/sbr_architecture/layout_sheets'

module Higeotoko::SbrArchitecture::Drawings
  META = 'test'
  def self.sheet_label(number) = format('A-%02d', number)
  def self.title(spec) = spec.fetch('name')
end

Scene = Struct.new(:number, :extent, :scene_index) do
  def get_attribute(_dictionary, key)
    { 'sheet_number' => number, 'extent_mm' => extent }.fetch(key)
  end
end

def view(number, kind, scale, extent, title = "#{kind} #{number}", scene_index: number)
  [Scene.new(number, extent, scene_index), { 'kind' => kind, 'name' => title }, scale]
end

def cells(page)
  page.last.map { |_, _, values| values.map(&:join) }
end

api = Higeotoko::SbrArchitecture
layout = api::LayoutSheets
index = api::DrawingIndex
plan = view(1, 'plan', 100, [9500, 7000], '平面 1FL')
partial = view(9, 'plan', 100, [3000, 2200], '平面 1FL｜水回り詳細')
elevations = (3..6).map { |number| view(number, 'elevation', 100, [7900, 7200]) }
sections = [view(7, 'section', 50, [11500, 4500]), view(8, 'section', 50, [12000, 4350])]
framing = view(10, 'framing', 50, [7500, 6000], '梁伏図 2FL')
plans = layout.drawing_sheets([plan, partial, *elevations, *sections, framing], 'grouped')
raise 'Single and grouped drawing numbers changed' unless plans.map(&:number) == %w[M-01 M-02 M-03 A-10]
raise 'Grouped drawing heading disagrees with the LayOut page name' unless plans.first.page_name == 'M-01｜一般平面図'
raise 'Wrong position on a two-view sheet' unless index.positions(plans[0].placements) == %w[左 右]
raise 'Wrong position on a four-view sheet' unless index.positions(plans[1].placements) == %w[左上 右上 左下 右下]
raise 'Wrong position on a stacked sheet' unless index.positions(plans[2].placements) == %w[上 下]

tables = [['T-01', '建具表'], ['T-01-02', '建具表（2）'], ['T-02', '室一覧']]
index_pages = index.pages(plans, tables)
raise 'Index did not get a separate number' unless index_pages.map(&:first) == ['I-01']
rows = cells(index_pages.first)
expected = ['A-09', '平面 1FL｜水回り詳細', '1:100', 'M-01', '右', '2']
raise 'The index did not map the reference drawing number to its actual publication' unless rows[1] == expected
raise 'A standalone sheet should use its own A-number' unless rows[8] == ['A-10', '梁伏図 2FL', '1:50', 'A-10', '', '5']
raise 'The tables do not point to their first sheet after the drawings' unless rows.last(2) == [
  ['T-01', '建具表', '', 'T-01', '', '6'], ['T-02', '室一覧', '', 'T-02', '', '8']
]
raise 'The table widths no longer match the A3 drawing frame' unless index_pages.first[4].sum == 392

selected = layout.drawing_sheets([partial], 'grouped')
raise 'A smaller publication inherited an old group number or location' unless
  cells(index.pages(selected, []).first).first == ['A-09', '平面 1FL｜水回り詳細', '1:100', 'A-09', '', '2']

many = (1..63).map { |number| view(number, 'plan', 50, [9500, 7000], '名前の長い部分平面' * 6) }
many_sheets = layout.drawing_sheets(many, 'single')
pages = index.pages(many_sheets, [])
raise 'Index overflow did not produce continuation pages' unless pages.size >= 3
raise 'Index page numbers are not consecutive' unless pages.map(&:first) == (1..pages.size).map { |n| format('I-%02d', n) }
all_rows = pages.flat_map { |page| cells(page) }
raise 'Adding continuation pages shifted the physical LayOut page numbers' unless
  all_rows.first.last == (pages.size + 1).to_s && all_rows.last.last == (pages.size + 63).to_s
raise 'An index row exceeded the A3 body' unless pages.all? do |page|
  page.last.all? { |top, height, _| top + height <= api::DrawingSchedules::BOTTOM + 0.001 }
end

if ARGV.first
  fixture = JSON.parse(File.read(ARGV.first, encoding: 'UTF-8'))
  entries = fixture.map do |item|
    number, title = item.fetch('name').split('   ', 2)
    view(number.delete_prefix('A-').to_i, item.fetch('kind'), item.fetch('scale'), item.fetch('extent'),
         title, scene_index: item.fetch('index'))
  end
  grouped = layout.drawing_sheets(entries, ARGV.fetch(2, 'grouped'))
  plan_data = grouped.map do |sheet|
    [sheet.number, sheet.title, sheet.page_name, sheet.placements.map do |(scene, spec, scale), frame, caption|
      [scene.scene_index, layout.drawing_number(scene), spec.fetch('name'), scale, frame, caption]
    end]
  end
  File.write(ARGV.fetch(1), JSON.generate(index: index.pages(grouped, []), drawings: plan_data), encoding: 'UTF-8')
end
puts 'Drawing index maps stable view numbers to actual LayOut sheets, positions and folios across pagination'
