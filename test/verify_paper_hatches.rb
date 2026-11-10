# frozen_string_literal: true

require_relative '../extension/sbr_architecture/layer_hatches'

layer = Higeotoko::SbrArchitecture::LayerHatches
polygon = [[0.0, 0.0], [1000.0, 0.0], [1000.0, 1000.0], [0.0, 1000.0]]
boundary = polygon.zip(polygon.rotate)
[50, 100].each do |denominator|
  lines = layer.lines(boundary, 0, spacing: layer::PAPER_PITCH_MM * denominator)
  paper_gaps = lines.map { |a, _| a.last / denominator }.each_cons(2).map { |a, b| b - a }
  raise 'Hatch pitch changed on paper' unless paper_gaps.all? { |gap| (gap - 1.7).abs < 1e-8 }
end
finish = { 'thickness' => 20, 'pattern' => 'diag' }
raise '20 mm finish should hatch at 1:50' unless layer.hatch_angles(finish, 50) == [45]
raise '20 mm finish should simplify at 1:100' unless layer.hatch_angles(finish, 100).empty?
raise 'Unhatched layer gained a pattern' unless layer.hatch_angles({ 'thickness' => 150, 'pattern' => 'none' }, 50).empty?
puts 'Paper hatch pitch and thin-layer checks passed'
