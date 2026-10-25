-- §3.20 spots: waterfalls (docs/SPEC.md FR-15.1).
ALTER TABLE spots DROP CONSTRAINT spots_category_check;
ALTER TABLE spots ADD CONSTRAINT spots_category_check
    CHECK (category IN ('playground', 'dog_park', 'monument', 'viewpoint', 'waterfall', 'history'));
