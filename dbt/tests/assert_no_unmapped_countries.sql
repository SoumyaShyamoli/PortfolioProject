/*
    Every country value in staging must appear in the country mapping seed.

    A new country arriving unmapped would otherwise produce a silent null in
    the country dimension, and the join would quietly drop or mis-attribute
    revenue. Failing here forces a deliberate decision about what the new
    value means.

    Unmappable values ('Unspecified', 'European Community', 'West Indies')
    ARE in the seed, with mapping_type = 'unmappable' and a null country id.
    They are mapped-as-unmappable, which is different from unmapped.
*/

select distinct
    s.country
from {{ ref('stg_orders') }} s
left join {{ ref('country_mapping') }} m
    on m.retail_country = s.country
where m.retail_country is null
