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

include("Boundaries.jl")
using .Boundaries

export Codes, Boundaries
export MunicipalBoundaries, CAOP_ATTRIBUTION,
       read_caop_geojson, contiguity, neighbour_lists, centroids,
       knn_contiguity, write_gal
export GeoLevel, COUNTRY, NUTS1, NUTS2, NUTS3, MUNICIPALITY,
       geolevel, isnuts3, ismunicipality, dico, nuts3, district,
       ismainland, isisland

end # module
