#
#
#
#
#
#
#
#
#
#
#
#
#
#
options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/noble/latest"))

install.packages(c("tidyverse", "sf", "terra", "fs", "geobr"))
#
#
#
# Load required libraries
library(tidyr)
library(dplyr)
library(sf)
library(terra)
library(geobr)
library(fs)

# Optimize terra memory usage (use only 50% of available RAM before swapping to disk)
terraOptions(memfrac = 0.5, tempdir = "data/temp")

# Ensure temp directory exists
if (!dir_exists("data/temp")) dir_create("data/temp")
#
#
#
#
#
#
# Define data directory path
data_dir <- "data"

# Create directory if it doesn't exist
if (!dir_exists(data_dir)) {
  dir_create(data_dir)
}

# Add data folder to .gitignore
gitignore_path <- ".gitignore"
ignore_entry <- "data/"

if (!file_exists(gitignore_path) || !any(str_detect(read_lines(gitignore_path), ignore_entry))) {
  write_lines(ignore_entry, gitignore_path, append = TRUE)
}
#
#
#
#
#
#
#
#
#
# Define the target years for our analysis
target_years <- c(1985, 1990, 1995, 2000, 2005, 2010, 2015, 2020, 2025)

# Create a character vector of local file paths
mapbiomas_files <- path(data_dir, str_glue("brazil_coverage-col11_{target_years}.tif"))

# Iterate over the years and download if missing
for (i in seq_along(target_years)) {
  yr <- target_years[i]
  file_path <- mapbiomas_files[i]
  
  if (!file_exists(file_path)) {
    url <- str_glue("[https://storage.googleapis.com/mapbiomas-public/initiatives/brasil/collection11/lulc/coverage/brazil_coverage/brazil_coverage-col11](https://storage.googleapis.com/mapbiomas-public/initiatives/brasil/collection11/lulc/coverage/brazil_coverage/brazil_coverage-col11)_{yr}.tif")
    
    download.file(
      url = url,
      destfile = file_path,
      mode = "wb"
    )
  }
}
#
#
#
#
#
#
#
# SGB WFS URLs
url_inundation <- "[https://geoportal.sgb.gov.br/server/services/gestaoterritorial/inundacao/MapServer/WFSServer](https://geoportal.sgb.gov.br/server/services/gestaoterritorial/inundacao/MapServer/WFSServer)"
url_flash_flood <- "[https://geoportal.sgb.gov.br/server/services/gestaoterritorial/enxurrada/MapServer/WFSServer](https://geoportal.sgb.gov.br/server/services/gestaoterritorial/enxurrada/MapServer/WFSServer)"
url_debris_flow <- "[https://geoportal.sgb.gov.br/server/services/gestaoterritorial/corrida_de_massa/MapServer/WFSServer](https://geoportal.sgb.gov.br/server/services/gestaoterritorial/corrida_de_massa/MapServer/WFSServer)"


# Helper function to download and read WFS layers
fetch_wfs_data <- function(base_url, file_name) {
  file_path <- path(data_dir, file_name)
  
  if (!file_exists(file_path)) {
    # Prefix with WFS: for GDAL/sf
    wfs_connection <- str_c("WFS:", base_url)
    
    # Automatically get the first layer name available in the service
    layer_info <- st_layers(wfs_connection)
    target_layer <- layer_info$name[1]
    
    # Read from WFS and save locally
    wfs_data <- st_read(wfs_connection, layer = target_layer)
    st_write(wfs_data, file_path, driver = "ESRI Shapefile")
  }
  
  # Read the local shapefile
  st_read(file_path, quiet = TRUE)
}

# Fetch all four datasets
inundation <- fetch_wfs_data(url_inundation, "inundation.shp")
flash_flood <- fetch_wfs_data(url_flash_flood, "flash_flood.shp")
debris_flow <- fetch_wfs_data(url_debris_flow, "debris_flow.shp")
mass_movement <- fetch_wfs_data(url_mass_movement, "mass_movement.shp")
#
#
#
#
#
susceptibility_path <- path(data_dir, "susceptibility_area.shp")

if (!file_exists(susceptibility_path)) {
  target_crs <- st_crs(inundation)
  
  # Combine polygons without unioning them to save massive amounts of RAM
  susceptibility_area <- bind_rows(
    inundation |> st_transform(target_crs) |> select(geometry),
    flash_flood |> st_transform(target_crs) |> select(geometry),
    debris_flow |> st_transform(target_crs) |> select(geometry),
    mass_movement |> st_transform(target_crs) |> select(geometry)
  ) |> 
    st_make_valid()
  
  st_write(susceptibility_area, susceptibility_path, driver = "ESRI Shapefile")
} else {
  susceptibility_area <- st_read(susceptibility_path, quiet = TRUE)
}

# Free RAM
rm(inundation, flash_flood, debris_flow, mass_movement)
gc()
#
#
#
#
#
#
#
# Download Brazilian municipalities (using 2022 census data as baseline)
municipalities <- read_municipality(year = 2022, showProgress = FALSE)

# Transform to match the susceptibility CRS
municipalities <- st_transform(municipalities, st_crs(susceptibility_area))

# Keep only municipalities that intersect with the susceptibility area
overlapped_munis <- st_filter(municipalities, susceptibility_area)

# Convert to standard data.frame (dropping geometry)
overlapped_df <- overlapped_munis |> 
  st_drop_geometry() |> 
  as_tibble()

# Preview the data
head(overlapped_df)
#
#
#
#
#
#
urban_expansion_path <- path(data_dir, "urban_expansion.tif")

if (!file_exists(urban_expansion_path)) {
  
  # Read the first raster merely to extract its CRS for projecting our vector
  template_raster <- rast(mapbiomas_files[1])
  
  susceptibility_vect <- vect(susceptibility_area) |> 
    project(crs(template_raster))
  
  rm(template_raster)
  gc()
  
  # Initialize an empty object to store the temporal urban compilation
  first_urban <- NULL
  
  # Iterate sequentially through the years
  for (i in seq_along(target_years)) {
    yr <- target_years[i]
    file_path <- mapbiomas_files[i]
    
    # 1. Load the raster and crop it strictly to the vector's bounding box
    mb_raster <- rast(file_path)
    mb_cropped <- crop(mb_raster, susceptibility_vect)
    
    # 2. Create boolean raster representing class 24 (Urban Area)
    is_urban <- mb_cropped == 24
    
    # 3. Consolidate into the master map
    if (is.null(first_urban)) {
      # For the first year (1985), if urban, assign year, else NA
      first_urban <- ifel(is_urban, yr, NA)
    } else {
      # For subsequent years, update pixel to current year ONLY IF:
      # - The pixel is currently urban (is_urban == TRUE)
      # - AND the pixel was NOT previously marked as urban (is.na(first_urban))
      first_urban <- ifel(is_urban & is.na(first_urban), yr, first_urban)
    }
    
    # Clean up intermediate heavy objects per iteration
    rm(mb_raster, mb_cropped, is_urban)
    gc()
  }
  
  # 4. Mask ONLY the final consolidated 1-band raster
  # This sets pixels completely outside the susceptibility polygons to NA
  final_urban_expansion <- mask(first_urban, susceptibility_vect)
  
  # 5. Save the output
  writeRaster(
    final_urban_expansion, 
    urban_expansion_path, 
    overwrite = TRUE, 
    datatype = "INT2U"
  )
}

# Clear vector from RAM
rm(susceptibility_area)
gc()

# Load and plot final result
urban_expansion <- rast(urban_expansion_path)
plot(urban_expansion, main = "First Year of Urbanization (1985-2025)", col = rev(terrain.colors(9)))
#
#
#
