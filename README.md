# JPX

Raster slippy map renderer for gps track viewing

**Dependencies**
- raylib
- libcurl (native)

## Usage
```
jpx [file] [OPTIONS]

file formats: gpx

OPTIONS:
    -s          map style (0 - 3)
    -k          api key for provided map style
    --offline   only use local cached tiles
```
| Style | Name             | Access Requirement                          |
|-------|------------------|---------------------------------------------|
| 0     | OSM              | Free                                        |
| 1     | Jawg terrain     | Needs key [Jawg](https://www.jawg.io/en/)   |
| 2     | Mapbox outdoors  | Needs key [Mapbox](https://www.mapbox.com/) |
| 3     | Mapbox satelite  | Needs key [Mapbox](https://www.mapbox.com/) |

### Config
the config file is **jpx.ini** in the same directory as the executable

You can add keys to the config file to always have access to those map styles
```
[Keys]
Jawg=YOUR_KEY
Mapbox=YOUR_KEY
```


## References
https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames 

https://en.wikipedia.org/wiki/Web_Mercator_projection
