# frozen_string_literal: true

require_relative '../extension/sbr_architecture/layout_sheets'

module Higeotoko::SbrArchitecture
  module Drawings
    META = 'test'
  end
end

Scene = Struct.new(:name, :extent, :authored) do
  def get_attribute(_dict, key)
    { 'extent_mm' => extent, 'paper_scale' => authored }.fetch(key)
  end
end

sheets = Higeotoko::SbrArchitecture::LayoutSheets
project = sheets.project_fields({ 'author' => '  山田  ', 'date' => '2028-02-29' }, '検証モデル')
raise 'Project name fallback or normalization is wrong' unless project == { 'name' => '検証モデル', 'number' => '', 'author' => '山田', 'date' => '2028-02-29' }
begin
  sheets.project_fields({ 'date' => '2026-02-29' }, '検証モデル')
  raise 'A non-existent issue date was accepted'
rescue ArgumentError => e
  raise unless e.message.include?('発行日')
end
raise 'The 1:50 viewport must retain readable joinery lines' unless sheets.viewport_line_weight(50) == 0.35
raise 'The 1:100 viewport needs thinner lines for close sash edges' unless sheets.viewport_line_weight(100) == 0.25
house = Scene.new('平面 1FL', [8300.0, 6500.0])
raise 'Auto should select 1:50' unless sheets.paper_scale(house, nil) == 50
raise 'Explicit 1:100 must stay 1:100' unless sheets.paper_scale(house, 100) == 100
authored = Scene.new('断面', [8300.0, 6500.0], 100)
raise 'Export should follow the saved scale' unless sheets.paper_scale(authored, nil) == 100
begin
  sheets.paper_scale(authored, 50)
  raise 'Scale different from its hatches must be rejected'
rescue ArgumentError => e
  raise unless e.message.include?('注記は1:100')
end
raise 'Larger elevation should select 1:100' unless sheets.paper_scale(Scene.new('立面', [19600.0, 7100.0]), nil) == 100
begin
  sheets.paper_scale(house, 20)
  raise 'An oversized sheet should be rejected'
rescue ArgumentError => e
  raise unless e.message.include?('A3に収まりません')
end
puts 'Drawing sheet scale checks passed'
