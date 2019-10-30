.DEFAULT_GOAL := readme


readme:
	j2 README.rst.j2 > README.rst
