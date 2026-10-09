# A minimal stand-in for how real research dashboards tend to arrive: the main
# file is named after the project rather than app.R, the data sits right next
# to the code and is read by bare file name, and the .Rprofile still activates
# an renv library that wasn't copied along. All three deploy without edits.
library(shiny)

stations <- read.csv("stations.csv")

ui <- fluidPage(
  titlePanel("Water quality stations"),
  selectInput("station", "Station", choices = stations$station),
  textOutput("reading")
)

server <- function(input, output) {
  output$reading <- renderText({
    row <- stations[stations$station == input$station, ]
    sprintf("Dissolved oxygen: %.1f mg/L", row$do_mg_l)
  })
}

shinyApp(ui, server)
