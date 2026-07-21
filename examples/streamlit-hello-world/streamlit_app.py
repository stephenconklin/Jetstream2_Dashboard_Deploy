# Minimal self-test app for the deploy tooling: a slider driving a line
# chart, using only generated data (no external data file needed) so it
# builds fast and confirms the whole pipeline (framework detection,
# `streamlit run`, port 80) works.
import numpy as np
import pandas as pd
import streamlit as st

st.title("Jetstream2 Dashboard Deploy — Streamlit self-test app")

points = st.slider("Number of points:", min_value=10, max_value=200, value=50)

rng = np.random.default_rng(42)
data = pd.DataFrame(
    {"x": range(points), "y": rng.standard_normal(points).cumsum()}
)

st.line_chart(data, x="x", y="y")
