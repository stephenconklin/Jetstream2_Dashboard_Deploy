# Minimal self-test app for the deploy tooling: the classic Shiny "Old
# Faithful" example. Only depends on `shiny` and base R's built-in datasets,
# so it builds fast regardless of which BASE_IMAGE is used, and confirms the
# whole pipeline (dependency auto-detection, Shiny Server, port 80) works.
library(shiny)

ui <- fluidPage(
  titlePanel("Jetstream2 Dashboard Deploy — R Shiny self-test app"),
  sidebarLayout(
    sidebarPanel(
      sliderInput("bins", "Number of bins:", min = 5, max = 30, value = 15)
    ),
    mainPanel(
      plotOutput("distPlot")
    )
  )
)

server <- function(input, output) {
  output$distPlot <- renderPlot({
    x <- faithful$waiting
    bins <- seq(min(x), max(x), length.out = input$bins + 1)
    hist(x, breaks = bins, col = "steelblue", border = "white",
         main = "Old Faithful Geyser Waiting Times", xlab = "Waiting time (minutes)")
  })
}

shinyApp(ui = ui, server = server)
