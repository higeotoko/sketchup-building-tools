# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    module MemberTags
      API = SbrArchitecture
      KEY = 'member_tags'
      Candidate = Struct.new(:id, :kind, :text, :axis, :outline) do
        def anchor(station)
          axis[0].zip(axis[1]).map { |a, b| a + (b - a) * station }
        end
      end
      module_function

      def entries(page)
        page ? JSON.parse(page.get_attribute(Drawings::META, KEY, '[]')) : []
      end

      def label(kind, params)
        type = kind == 'column' ? '柱' : '梁'
        system = Catalog::SYSTEMS[params['system']]
        profile = if params['system'] == 'steel'
                    params['section_id']
                  else
                    params.values_at('width', 'depth').map { |value| format('%g', value) }.join('×')
                  end
        "#{type}｜#{[system, profile].compact.join(' ')}"
      end

      def beam_candidate(beam)
        params = Follow.parameters(beam)
        outline = FramingPlan.footprint(beam, params)
        return if outline.size < 3

        Candidate.new(beam.persistent_id, 'beam', label('beam', params), FramingPlan.beam_axis(beam, params), outline)
      end

      def column_candidate(column, cut)
        center = PlanDimensions.column_center(column, cut).first
        section = ColumnCuts.section(column, cut) if center
        return unless section

        Candidate.new(column.persistent_id, 'column', label('column', Follow.parameters(column)), [center.a, center.a], section.first)
      end

      def candidates(model, data, datum, hidden, groups, ids: nil, framing: nil, overhead: nil)
        if data['kind'] == 'framing'
          beams = framing || FramingPlan.select_beams(groups, datum, data.fetch('top_tolerance'), hidden)
          column_cut = FramingPlan.column_cut(beams)
        else
          floor = API.levels(model).fetch(data.fetch('level'))
          bottom = floor + data['plan_bottom'] if data.key?('plan_bottom')
          overhead ||= data['plan_top'] ? PlanRange.overhead_beams(groups, datum, floor + data['plan_top'], hidden) : []
          beams = groups.select do |group|
            next false unless Follow.kind(group) == 'beam' && !hidden.include?(group.persistent_id) && group.layer.visible?

            bottom ? !PlanRange.outside?(group, bottom, datum) : !Drawings.outside_plan?(group, data.fetch('level'), floor, datum)
          end + overhead
          column_cut = datum
        end
        columns = groups.select do |group|
          column_cut && Follow.kind(group) == 'column' && !hidden.include?(group.persistent_id) && group.layer.visible?
        end
        beams = beams.select { |beam| ids.include?(beam.persistent_id) } if ids
        columns = columns.select { |column| ids.include?(column.persistent_id) } if ids
        result = beams.filter_map { |beam| beam_candidate(beam) }
        result.concat(columns.filter_map { |column| column_candidate(column, column_cut) })
        result.to_h { |candidate| [candidate.id, candidate] }
      end

      def label_box(text, point, offset, denominator)
        width = (text.each_char.sum { |char| char.ascii_only? ? 2.1 : 3.6 } + 2.5) * denominator
        x, y = point
        left, right = offset[0].negative? ? [x - width, x] : [x, x + width]
        low, high = [y - 1.5 * denominator, y + 3.8 * denominator]
        [[left, low], [right, low], [right, high], [left, high]]
      end

      def placement(candidate, station, offset, crop, denominator)
        anchor = candidate.anchor(station)
        point = anchor.zip(offset).map { |a, b| a + b }
        box = label_box(candidate.text, point, offset, denominator)
        return unless Math.hypot(*offset) >= 1 && PlanDimensions.within_crop?([anchor, *box], crop)

        [anchor, point, box]
      end

      def pick(point, candidates, tolerance, crop)
        candidates.filter_map do |candidate|
          outline = candidate.outline
          distance = if ColumnCuts.contains?(outline, point)
                       0
                     else
                       outline.zip(outline.rotate).map do |a, b|
                         t = PlanDimensions.foot(point, a, b).clamp(0, 1)
                         Math.hypot(*point.zip(a, b).map { |p, u, v| p - u - (v - u) * t })
                       end.min
                     end
          next if distance > tolerance

          station = PlanDimensions.foot(point, *candidate.axis).clamp(0, 1).round(8)
          next unless PlanDimensions.within_crop?([candidate.anchor(station)], crop)

          [distance, candidate.kind == 'column' ? 0 : 1, candidate, station]
        end.min_by { |distance, priority, _, _| [distance, priority] }&.last(2)
      end

      def draw(entities, datum, crop, entries, candidates, denominator)
        masks = []
        tagged = []
        values = entries.to_h do |entry|
          candidate = candidates[entry.fetch('member_id')]
          offset = entry.fetch('offset')
          position = placement(candidate, entry.fetch('station'), offset, crop, denominator) if candidate
          text = nil
          if position
            anchor, _, box = position
            mark = entities.add_text(candidate.text, API.point(*anchor, datum - 0.12),
                                     Geom::Vector3d.new(offset[0].mm, offset[1].mm, 0))
            raise ArgumentError, '部材タグを描けませんでした。' unless mark

            mark.leader_type = ALeaderModel
            mark.arrow_type = Sketchup::Dimension::ARROW_DOT
            mark.font = { size: 9 } if mark.respond_to?(:font=)
            masks << ColumnCuts.mask_for([box])
            tagged << candidate.id
            text = candidate.text
          end
          [entry.fetch('id'), text]
        end
        [values, masks, tagged]
      end
    end
  end
end
