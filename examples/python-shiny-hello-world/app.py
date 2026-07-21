# Minimal self-test app for the deploy tooling: a slider driving a
# histogram, analogous to the R Shiny "Old Faithful" example. Only depends
# on `shiny` plus a tiny plotting stack, so it builds fast and confirms the
# whole pipeline (framework detection, `shiny run`, port 80) works.
import matplotlib
import numpy as np
from shiny import App, render, ui

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

np.random.seed(42)
WAITING_TIMES = np.random.normal(loc=70, scale=14, size=272)

app_ui = ui.page_fluid(
    ui.h2("Jetstream2 Dashboard Deploy — Python Shiny self-test app"),
    ui.input_slider("bins", "Number of bins:", min=5, max=30, value=15),
    ui.output_plot("dist_plot"),
)


def server(input, output, session):
    @render.plot
    def dist_plot():
        fig, ax = plt.subplots()
        ax.hist(WAITING_TIMES, bins=input.bins(), color="steelblue", edgecolor="white")
        ax.set_title("Simulated Waiting Times")
        ax.set_xlabel("Waiting time (minutes)")
        return fig


app = App(app_ui, server)
