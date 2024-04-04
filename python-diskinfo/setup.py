from setuptools import setup, find_packages

setup(
    name='diskinfo',
    packages=find_packages(include=['src']),
    version='0.1.0',
    description='Disk information Python library for Linux',
    author='Peter Sulyok',
    license='MIT',
)