# frozen_string_literal: true

require 'json'
require_relative '../extension/sbr_architecture/layout_sheets'
require_relative '../extension/sbr_architecture/publication_sets'

module Higeotoko::SbrArchitecture
  module Drawings
    META = 'test'
  end
end

Scene = Struct.new(:name, :extent) do
  def get_attribute(_dictionary, _key) = extent
end

sheets = Higeotoko::SbrArchitecture::LayoutSheets
def entry(id, kind, width, height, scale = 50)
  [Scene.new(id, [width, height]), { 'kind' => kind }, scale]
end

plans = [entry('A-01', 'plan', 8200, 6700), entry('A-02', 'plan', 8500, 6900)]
elevations = (3..6).map { |id| entry("A-0#{id}", 'elevation', 7900, 7200, 100) }
sections = [entry('A-07', 'section', 11500, 4500), entry('A-08', 'section', 12000, 4350)]
framing = entry('A-09', 'framing', 7300, 6200)
entries = [*plans, *elevations, *sections, framing]
arranged = sheets.arrange(entries, 'grouped')
raise 'Expected sideways plans, four elevations, stacked sections and a single framing view' unless arranged.map(&:size) == [2, 4, 2, 1]
raise 'A view was lost or reordered within its kind' unless arranged.flat_map { |placements| placements.map(&:first) } == entries
raise 'Wide sections should stack' unless arranged[2].map { |_, frame, _| frame.first }.uniq.one?
raise 'Plans should sit side by side' unless arranged[0].map { |_, frame, _| frame[1] }.uniq.one?

arranged.each do |placements|
  used = placements.flat_map do |entry, frame, caption|
    x, y, w, h = frame
    unless x >= 14 && y >= 29 && x + w <= 406.001 && y + h <= 273.001
      raise 'A viewport exceeded the paper frame'
    end
    next [frame] unless caption

    width, height = sheets.paper_extent(entry)
    if width + sheets::PANEL_WIDTH_MARGIN_MM > w + 0.001 || height + sheets::PANEL_HEIGHT_MARGIN_MM > h + 0.001
      raise 'An authored-scale view was clipped'
    end
    [frame, caption]
  end
  used.combination(2).each do |(x, y, w, h), (u, v, a, b)|
    raise 'Two viewports or captions overlap' if x < u + a && u < x + w && y < v + b && v < y + h
  end
end
raise 'Default arrangement changed' unless sheets.arrange(entries, 'single').all? { |items| items.one? && items.first[2].nil? }
large = entry('oversized', 'plan', 17000, 9000)
raise 'Large plans were scaled down or forced together' unless sheets.arrange([large, *plans], 'grouped').map(&:size) == [1, 2]
raise 'Mixed scales were grouped' unless sheets.arrange([plans.first, entry('other', 'plan', 8500, 6900, 100)], 'grouped').map(&:size) == [1, 1]
raise 'Three elevations were not grouped when the fourth did not fit' unless
  sheets.arrange([*elevations.first(3), entry('wide', 'elevation', 19000, 13000, 100)], 'grouped').map(&:size) == [3, 1]

if ARGV.first
  fixture = JSON.parse(File.read(ARGV.first, encoding: 'UTF-8'))
  views = fixture.map do |item|
    [Scene.new(item.fetch('index'), item.fetch('extent')), item, item.fetch('scale')]
  end
  views = Higeotoko::SbrArchitecture::PublicationSets.drawing_subset(views, ARGV.drop(2)) if ARGV.size > 2
  export = sheets.arrange(views, 'grouped').map do |placements|
    placements.map { |(scene, spec, scale), frame, caption| [scene.name, spec.fetch('name'), scale, frame, caption] }
  end
  File.write(ARGV.fetch(1), JSON.generate(export), encoding: 'UTF-8')
end
puts 'LayOut arrangement preserves view scales, limits, captions, sheet separation and order'
