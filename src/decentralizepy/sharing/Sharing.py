import json
import logging
from collections import deque

import numpy
import torch


class Sharing:
    """
    API defining who to share with and what, and what to do on receiving
    """

    def __init__(self, rank, machine_id, communication, mapping, graph, model, dataset):
        """
        Constructor
        Parameters
        ----------
        rank : int
            Local rank
        machine_id : int
            Global machine id
        communication : decentralizepy.communication.Communication
            Communication module used to send and receive messages
        mapping : decentralizepy.mappings.Mapping
            Mapping (rank, machine_id) -> uid
        graph : decentralizepy.graphs.Graph
            Graph reprensenting neighbors
        model : decentralizepy.models.Model
            Model to train
        dataset : decentralizepy.datasets.Dataset
            Dataset for sharing data. Not implemented yer! TODO
        log_dir : str
            Location to write shared_params (only writing for 2 procs per machine)
        """
        self.rank = rank
        self.machine_id = machine_id
        self.uid = mapping.get_uid(rank, machine_id)
        self.communication = communication
        self.mapping = mapping
        self.graph = graph
        self.model = model
        self.dataset = dataset
        self.communication_round = 0

        self.peer_deques = dict()
        my_neighbors = self.graph.neighbors(self.uid)
        for n in my_neighbors:
            self.peer_deques[n] = deque()

    def received_from_all(self):
        """
        Check if all neighbors have sent the current iteration
        Returns
        -------
        bool
            True if required data has been received, False otherwise
        """
        for _, i in self.peer_deques.items():
            if len(i) == 0:
                return False
        return True

    def get_neighbors(self, neighbors):
        """
        Choose which neighbors to share with
        Parameters
        ----------
        neighbors : list(int)
            List of all neighbors
        Returns
        -------
        list(int)
            Neighbors to share with
        """
        # modify neighbors here
        return neighbors

    def serialized_model(self):
        """
        Convert model to json dict. Here we can choose how much to share
        Returns
        -------
        dict
            Model converted to json dict
        """
        m = dict()
        for key, val in self.model.state_dict().items():
            m[key] = json.dumps(val.numpy().tolist())
        return m

    def deserialized_model(self, m):
        """
        Convert received json dict to state_dict.
        Parameters
        ----------
        m : dict
            json dict received
        Returns
        -------
        state_dict
            state_dict of received
        """
        state_dict = dict()
        for key, value in m.items():
            state_dict[key] = torch.from_numpy(numpy.array(json.loads(value)))
        return state_dict

    def step(self):
        data = self.serialized_model()
        my_uid = self.mapping.get_uid(self.rank, self.machine_id)
        all_neighbors = self.graph.neighbors(my_uid)
        iter_neighbors = self.get_neighbors(all_neighbors)
        data["degree"] = len(all_neighbors)
        data["iteration"] = self.communication_round
        for neighbor in iter_neighbors:
            self.communication.send(neighbor, data)

        logging.info("Waiting for messages from neighbors")
        while not self.received_from_all():
            sender, data = self.communication.receive()
            logging.debug("Received model from {}".format(sender))
            degree = data["degree"]
            iteration = data["iteration"]
            del data["degree"]
            del data["iteration"]
            self.peer_deques[sender].append((degree, iteration, data))
            logging.info(
                "Deserialized received model from {} of iteration {}".format(
                    sender, iteration
                )
            )

        logging.info("Starting model averaging after receiving from all neighbors")
        total = dict()
        weight_total = 0
        for i, n in enumerate(self.peer_deques):
            degree, iteration, data = self.peer_deques[n].popleft()
            logging.debug(
                "Averaging model from neighbor {} of iteration {}".format(i, iteration)
            )
            data = self.deserialized_model(data)
            weight = 1 / (max(len(self.peer_deques), degree) + 1)  # Metro-Hastings
            weight_total += weight
            for key, value in data.items():
                if key in total:
                    total[key] += value * weight
                else:
                    total[key] = value * weight

        for key, value in self.model.state_dict().items():
            total[key] += (1 - weight_total) * value  # Metro-Hastings

        self.model.load_state_dict(total)

        logging.info("Model averaging complete")

        self.communication_round += 1
