# Minimal self-test app for the deploy tooling: a single dropdown driving a
# Plotly bar chart, using only bundled sample data (no external data file
# needed) so it builds fast and confirms the whole pipeline (framework
# detection, gunicorn, port 80) works.
import plotly.express as px
from dash import Dash, Input, Output, dcc, html

df = px.data.gapminder().query("year == 2007")
CONTINENTS = sorted(df["continent"].unique())

app = Dash(__name__)
server = app.server  # exposed for gunicorn: `gunicorn app:server`

app.layout = html.Div(
    [
        html.H1("Jetstream2 Dashboard Deploy — Dash self-test app"),
        dcc.Dropdown(
            id="continent",
            options=[{"label": c, "value": c} for c in CONTINENTS],
            value=CONTINENTS[0],
        ),
        dcc.Graph(id="pop-by-country"),
    ]
)


@app.callback(Output("pop-by-country", "figure"), Input("continent", "value"))
def update_chart(continent):
    filtered = df[df["continent"] == continent]
    return px.bar(filtered, x="country", y="pop", title=f"Population — {continent}")


if __name__ == "__main__":
    app.run_server(host="0.0.0.0", port=8050, debug=False)
