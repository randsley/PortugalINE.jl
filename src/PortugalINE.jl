"""
    PortugalINE

A client for Statistics Portugal (INE), built for spatial work: the geography
codes, the indicator API, and weights matrices from INE's own geometry.

Data from INE is open for reuse, commercially and otherwise, under EU Directive
2019/1024. INE retains copyright, and reuse carries one condition: cite the
source. This package records provenance with every extract so that citation can
be written without guessing when the data was pulled.
"""
module PortugalINE

include("Codes.jl")
using .Codes

include("Indicators.jl")
using .Indicators

include("Boundaries.jl")
using .Boundaries

include("Join.jl")
using .Join

include("Panel.jl")
using .Panel

export Codes, Indicators, Boundaries, Join, Panel
export MunicipalDataset, join_municipal, spatial_weights, model_matrix,
       write_dataset, dropped, notes
export PanelDataset, join_panel, panel_matrices, write_panel
export INE_ATTRIBUTION, DimensionCategory, Dimension, Indicator, IndicatorData,
       CatalogueEntry,
       indicator_metadata, indicator_data, catalogue, catalogue_entry,
       municipal_values, parish_values, period_code, periods, ismunicipal, search_catalogue,
       ine_cache_dir, clear_ine_cache!, cache_response!, cache_max_age, ine_citation,
       parse_value
export MunicipalBoundaries, CAOP_ATTRIBUTION,
       read_caop_geojson, contiguity, neighbour_lists, centroids,
       knn_contiguity, write_gal
export GeoLevel, COUNTRY, NUTS1, NUTS2, NUTS3, MUNICIPALITY, PARISH,
       geolevel, isnuts3, ismunicipality, isparish, ispseudo, dico, dicofre, nuts3, district,
       ismainland, isisland

end # module
