# frozen_string_literal: true

module Higeotoko
  module SbrArchitecture
    class MemberTagPlacement
      API = SbrArchitecture

      def initialize(model, page, data, datum, candidates, &finish)
        @model, @page, @crop, @datum = model, page, data['plan_crop'], datum
        @candidates, @finish = candidates.values, finish
        @scale = page.get_attribute(Drawings::META, 'paper_scale', 50)
      end

      def activate
        prompt
      end

      def resume(view)
        prompt
        view.invalidate
      end

      def deactivate(view)
        view.invalidate
        complete(nil)
      end

      def cancel
        @model.select_tool(nil) if @finish
      end

      def onCancel(reason, _view)
        cancel if reason.zero?
      end

      def current?(view)
        @model.pages.selected_page == @page && SectionPlacement.top_view?(view)
      end

      def onMouseMove(_flags, x, y, view)
        @hit = @position = @offset = nil
        if current?(view)
          cursor = Geom.intersect_line_plane(view.pickray(x, y), [API.point(0, 0, @datum), Z_AXIS])
          if cursor
            xy = PlanDimensions.xy(cursor)
            if @candidate
              @offset = xy.zip(@candidate.anchor(@station)).map { |a, b| (a - b).round(2) }
              @position = MemberTags.placement(@candidate, @station, @offset, @crop, @scale)
            else
              @hit = MemberTags.pick(xy, @candidates, view.pixels_to_model(9, cursor).to_mm, @crop)
              view.tooltip = @hit.first.text if @hit
            end
          end
        else
          Sketchup.set_status_text('部材タグを入れる平面に戻るか、Escで終了してください。', SB_PROMPT)
        end
        view.invalidate
      end

      def onLButtonDown(flags, x, y, view)
        onMouseMove(flags, x, y, view)
        if @position
          complete({ 'id' => SecureRandom.uuid, 'member_id' => @candidate.id, 'station' => @station, 'offset' => @offset })
        elsif @hit
          @candidate, @station = @hit
          prompt
        elsif @candidate && current?(view)
          Sketchup.set_status_text('タグの文字が収まる場所をクリックしてください。Escで終了。', SB_PROMPT)
        end
      end

      def draw(view)
        return unless current?(view)

        candidate = @candidate || @hit&.first
        return unless candidate

        view.drawing_color = Sketchup::Color.new(0, 157, 163)
        view.line_width = 2
        view.draw2d(GL_LINE_LOOP, candidate.outline.map { |xy| screen(view, xy) })
        return unless @position

        anchor, position, box = @position
        view.draw2d(GL_LINES, [anchor, position].map { |xy| screen(view, xy) })
        view.draw_text(screen(view, box.last), candidate.text)
      end

      private

      def screen(view, xy)
        view.screen_coords(API.point(*xy, @datum))
      end

      def prompt
        message = @candidate ? '② タグを置く位置をクリック。' : '① 柱または梁をクリック。'
        Sketchup.set_status_text("#{message} Escで終了。", SB_PROMPT)
      end

      def complete(entry)
        callback, @finish = @finish, nil
        @model.select_tool(nil) if entry
        callback&.call(entry)
      end
    end
  end
end
